lapis = require "lapis"
config = require("lapis.config").get!

import respond_to, json_params from require "lapis.application"
import hmac_sha1, hmac_sha256 from require "lapis.util.encoding"
import encode from require "cjson"
import GithookLogs from require "models"
import locate, autoload, registry from require "locator"
import settings from autoload "utility"
import execute from locate "utility.shell"
import insert, concat from table

const_compare = (string1, string2) ->
  local fail, dummy

  for i = 1, math.max #string1, #string2
    if string1\sub(i,i) ~= string2\sub(i,i)
      fail = true
    else
      dummy = true -- attempting to make execution time equal

  return not fail

hex_dump = (str) ->
  len = string.len str
  hex = ""

  for i = 1, len
    hex ..= string.format( "%02x", string.byte( str, i ) )

  return hex

run_update = (branch) ->
  exit_codes, logs = {}, {}
  failure = false

  commands = registry.githook_commands branch, config._name
  unless commands
    commands = {
      {"git checkout #{branch} 2> /dev/stdout"}
      {"git pull origin 2> /dev/stdout"}
      {"git submodule init 2> /dev/stdout"}
      {"git submodule update 2> /dev/stdout"}
      {"code=0\nfor file in $(find . -type f -name \"*.moon\"); do moonc \"$file\" 2> /dev/stdout\ntmp=$?\nif [ ! $tmp -eq 0 ]; then code=$tmp\nfi; done\necho $code", false}
      {"lapis migrate #{config._name} 2> /dev/stdout"}
      {"lapis build #{config._name} 2> /dev/stdout"}
    }
  for cmd in *commands
    code, output = execute unpack cmd
    insert exit_codes, code
    insert logs, output
    failure = true if code != 0

  log = concat logs, "\n"

  if failure
    if settings["githook.save_logs"]
      GithookLogs\create {
        success: false
        exit_codes: encode exit_codes
        :log
      }
    return status: 500, json: {
      status: "failure"
      message: "a subprocess returned a non-zero exit code"
      :log
      :exit_codes
    }
  else
    if settings["githook.save_logs"] and settings["githook.save_on_success"]
      GithookLogs\create {
        exit_codes: encode exit_codes
        :log
      }
    elseif settings["githook.save_logs"]
      GithookLogs\create! -- we still record WHEN there was a success
    return status: 200, json: {
      status: "success"
      message: "server updated to latest version of '#{branch}'"
      :log
      :exit_codes
    }

ignored = (branch) ->
  return status: 200, json: {
    status: "success"
    message: "ignored push (looking for updates to '#{branch}')"
  }

unauthorized = ->
  return status: 401, json: {
    status: "unauthorized",
    message: "invalid credentials or no credentials were sent"
  }

invalid = (reason) ->
  return status: 400, json: {
    status: "invalid request"
    message: reason
  }

class extends lapis.Application
  [githook: "/githook"]: respond_to {
    before: =>
      @branch = config.githook_branch or settings["githook.branch"] or "master"

    GET: =>
      unless settings["githook.allow_get"]
        return status: 405, json: {
          status: "method not allowed",
          message: "Githook is not accepting GET requests."
        }

      unless settings["githook.run_without_auth"]
        return unauthorized!

      @results = run_update(@branch)
      return render: locate "views.githook_get"

    POST: json_params =>
      if config.githook_secret
        ngx.req.read_body!
        if body = ngx.req.get_body_data!
          local authorized
          if github_hash = @req.headers["X-Hub-Signature"]
            authorized = const_compare "sha1=#{hex_dump hmac_sha1 config.githook_secret, body}", github_hash
          elseif gogs_hash = @req.headers["X-Gogs-Signature"]
            authorized = const_compare gogs_hash, hex_dump hmac_sha256 config.githook_secret, body
          unless authorized
            return unauthorized!
          if @params.ref == "refs/heads/#{@branch}"
            return run_update(@branch)
          elseif @params.ref == nil
            return invalid "'ref' not defined in request body"
          else
            return ignored(@branch)
        else
          return invalid "no request body"
      elseif settings["githook.run_without_auth"]
        if @params.ref == "refs/heads/#{@branch}"
          return run_update(@branch)
        else
          return ignored(@branch)
      else
        return unauthorized!
    }
