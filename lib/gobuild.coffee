spawn = require('child_process').spawn
fs = require 'fs-plus'
path = require 'path'
{Subscriber, Emitter} = require 'emissary'

module.exports =
class Gobuild
  Subscriber.includeInto(this)
  Emitter.includeInto(this)

  constructor: (dispatch) ->
    atom.workspaceView.command 'golang:gobuild', => @checkCurrentBuffer()
    @dispatch = dispatch
    @name = 'syntaxcheck'

  destroy: ->
    @unsubscribe

  reset: (editorView) ->
    @emit 'reset', editorView

  checkCurrentBuffer: ->
    editorView = atom.workspaceView.getActiveView()
    return unless editorView?
    @reset editorView
    @checkBuffer(editorView, false)

  checkBuffer: (editorView, saving) ->
    unless @dispatch.isValidEditorView(editorView)
      @emit @name + '-complete', editorView, saving
      return
    if saving and not atom.config.get('go-plus.syntaxCheckOnSave')
      @emit @name + '-complete', editorView, saving
      return
    buffer = editorView?.getEditor()?.getBuffer()
    unless buffer?
      @emit @name + '-complete', editorView, saving
      return
    gopath = @dispatch.buildGoPath()
    if not gopath? or gopath is ''
      errors = []
      error =
          line: false
          column: false
          msg: 'Warning: GOPATH is not set – either set the GOPATH environment variable or define the Go Path in go-plus package preferences'
      errors.push error
      @emit @name + '-errors', editorView, errors
      @emit @name + '-complete', editorView, saving
      return
    env = process.env
    env['GOPATH'] = gopath
    re = new RegExp(buffer.getBaseName() + '$')
    cwd = buffer.getPath().replace(re, '')
    output = ''
    args = []
    if buffer.getPath().match(/_test.go$/i)
      pre = /^\w*package ([\d\w]+){1}\w*$/img # Need To Support Unicode Letters Also
      match = pre.exec(buffer.getText())
      testPackage = match[1]
      testPackage = testPackage.replace(/_test$/i, '')
      output = testPackage + '.test'
      args = ['test', '-c', buffer.getPath()]
    else
      output = '.go-plus-syntax-check'
      args = ['build', '-o', output, '.']
    cmd = atom.config.get('go-plus.goExecutablePath')
    errored = false
    proc = spawn(cmd, args, {cwd: cwd, env: env})
    proc.on 'error', (error) =>
      return unless error?
      errored = true
      console.log @name + ': error launching command [' + cmd + '] – ' + error  + ' – current PATH: [' + process.env.PATH + ']'
      errors = []
      error = line: false, column: false, type: 'error', msg: 'Go Executable Not Found @ ' + cmd
      errors.push error
      @emit @name + '-errors', editorView, errors
      @emit @name + '-complete', editorView, saving
    proc.stderr.on 'data', (data) => @mapErrors(editorView, data, buffer.getBaseName())
    proc.stdout.on 'data', (data) => console.log @name + ': ' + data if data?
    proc.on 'close', (code) =>
      console.log @name + ': [' + cmd + '] exited with code [' + code + ']' if code isnt 0
      syntaxCheckOutputFile = path.join(cwd, output)
      if fs.existsSync(syntaxCheckOutputFile)
        fs.unlinkSync(syntaxCheckOutputFile)
      @emit @name + '-complete', editorView, saving unless errored

  mapErrors: (editorView, data, filename) ->
    pattern = /^(\.\/)?(.*?):(\d*?):((\d*?):)?\s((.*)?((\n\t.*)+)?)/img
    errors = []
    fre = new RegExp('^' + filename + '$', 'i')
    extract = (matchLine) ->
      return unless matchLine?
      file = matchLine[2]?.replace(/^.*[\\\/]/, '')
      if file?
        return unless file.match(fre)
      error = switch
        when matchLine[5]?
          line: matchLine[3]
          column: matchLine[5]
          msg: matchLine[6]
          type: 'error'
        else
          line: matchLine[3]
          column: false
          msg: matchLine[6]
          type: 'error'
      errors.push error
    loop
      match = pattern.exec(data)
      extract(match)
      break unless match?
    @emit @name + '-errors', editorView, errors