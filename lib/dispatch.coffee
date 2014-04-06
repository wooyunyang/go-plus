{Subscriber, Emitter} = require 'emissary'
Gofmt = require './gofmt'
Govet = require './govet'
Golint = require './golint'
Gobuild = require './gobuild'
_ = require 'underscore-plus'
$ = require('atom').$
{MessagePanelView, LineMessageView, PlainMessageView} = require 'atom-message-panel'

module.exports =
class Dispatch
  Subscriber.includeInto(this)
  Emitter.includeInto(this)

  constructor: ->
    @errorCollection = []
    @gofmt = new Gofmt(this)
    @govet = new Govet(this)
    @golint = new Golint(this)
    @gobuild = new Gobuild(this)
    @messagepanel = new MessagePanelView title: '<span class="icon-diff-added"></span> go-plus', rawTitle: true

    # Pipeline For Processing Buffer
    @gofmt.on 'fmt-complete', (editorView, saving) =>
      @emit 'fmt-complete', editorView, saving
      @govet.checkBuffer(editorView, saving) if saving
      @emit 'dispatch-complete', editorView if not saving
    @govet.on 'vet-complete', (editorView, saving) =>
      @emit 'vet-complete', editorView, saving
      @golint.checkBuffer(editorView, saving) if saving
      @emit 'dispatch-complete', editorView if not saving
    @golint.on 'lint-complete', (editorView, saving) =>
      @emit 'lint-complete', editorView, saving
      @gobuild.checkBuffer(editorView, saving) if saving
      @emit 'dispatch-complete', editorView if not saving
    @gobuild.on 'syntaxcheck-complete', (editorView, saving) =>
      @emit 'syntaxcheck-complete', editorView, saving
      @emit 'dispatch-complete', editorView

    # Collect Errors
    @gofmt.on 'fmt-errors', (editorView, errors) =>
      @collectErrors(errors)
    @govet.on 'vet-errors', (editorView, errors) =>
      @collectErrors(errors)
    @golint.on 'lint-errors', (editorView, errors) =>
      @collectErrors(errors)
    @gobuild.on 'syntaxcheck-errors', (editorView, errors) =>
      @collectErrors(errors)

    # Reset State If Requested
    @gofmt.on 'reset', (editorView) =>
      @resetState(editorView)
    @golint.on 'reset', (editorView) =>
      @resetState(editorView)
    @govet.on 'reset', (editorView) =>
      @resetState(editorView)
    @gobuild.on 'reset', (editorView) =>
      @resetState(editorView)

    # Update Pane And Gutter With Errors
    @on 'dispatch-complete', (editorView) =>
      @updatePane(editorView, @errorCollection)
      @updateGutter(editorView, @errorCollection)
    atom.workspaceView.eachEditorView (editorView) => @handleEvents(editorView)
    atom.workspaceView.on 'pane-container:active-pane-item-changed', =>
      @resetPanel()
      @messagepanel.close()

  collectErrors: (errors) ->
    @errorCollection = _.union(@errorCollection, errors)
    @errorCollection = _.uniq @errorCollection, (element, index, list) ->
      return element.line + ":" + element.column + ":" + element.msg
    @emit 'errors-collected', _.size(@errorCollection)

  destroy: ->
    @unsubscribe
    @gobuild.destroy()
    @golint.destroy()
    @govet.destroy()
    @gofmt.destroy()

  handleEvents: (editorView) ->
    editor = editorView.getEditor()
    buffer = editor.getBuffer()
    buffer.on 'saved', => @handleBufferSave(editorView, true)
    editor.on 'destroyed', => buffer.off 'saved'

  handleBufferSave: (editorView, saving) ->
    editor = editorView.getEditor()
    grammar = editor.getGrammar()
    return if grammar.scopeName isnt 'source.go'
    @resetState(editorView)
    @gofmt.formatBuffer(editorView, saving)

  resetState: (editorView) ->
    @errorCollection = []
    @resetGutter(editorView)
    @resetPanel()

  resetGutter: (editorView) ->
    gutter = editorView?.gutter
    return unless gutter?
    gutter.removeClassFromAllLines('go-plus-error')

  updateGutter: (editorView, errors) ->
    @resetGutter(editorView)
    return unless errors?
    return if errors.length <= 0
    gutter = editorView?.gutter
    return unless gutter?
    gutter.addClassToLine error.line - 1, 'go-plus-error' for error in errors

  resetPanel: ->
    @messagepanel.clear()

  updatePane: (editorView, errors) ->
    @resetPanel
    return unless errors?
    if errors.length <= 0
      @messagepanel.add new PlainMessageView message: 'No Issues', className: 'text-success'
      @messagepanel.attach()
      return
    return unless atom.config.get('go-plus.showErrorPanel')
    sortedErrors = _.sortBy @errorCollection, (element, index, list) ->
      return parseInt(element.line, 10)
    for error in sortedErrors
      className = switch error.type
        when 'error' then 'text-error'
        when 'warning' then 'text-warning'
        else 'text-info'

      if error.line isnt false and error.column isnt false
        # LineMessageView
        @messagepanel.add new LineMessageView line: error.line, character: error.column, message: error.msg, className: className
      else if error.line isnt false and error.column is false
        # LineMessageView
        @messagepanel.add new LineMessageView line: error.line, message: error.msg, className: className
      else
        # PlainMessageView
        @messagepanel.add new PlainMessageView message: error.msg, className: className
    @messagepanel.attach()

  buildGoPath: ->
    gopath = ''
    gopathEnv = process.env.GOPATH
    gopathConfig = atom.config.get('go-plus.goPath')
    environmentOverridesConfig = atom.config.get('go-plus.environmentOverridesConfiguration')
    environmentOverridesConfig ?= true
    gopath = gopathEnv if gopathEnv? and gopathEnv isnt ''
    gopath = gopathConfig if not environmentOverridesConfig and gopathConfig? and gopathConfig isnt ''
    gopath = gopathConfig if gopath is ''
    return gopath

  isValidEditorView: (editorView) ->
    editorView?.getEditor()?.getGrammar()?.scopeName is 'source.go'

  # updateStatus: (errors, row) ->
  #   msg = ''
  #   return if not errors? or errors == false
  #   return if errors.length <= 0
  #   lineErrors = _.filter(errors, (error) -> error[0] is row + 1)
  #   return if not lineErrors?
  #   return if lineErrors.length <= 0
  #   msg = 'Error: ' + lineErrors[0][0] + ':' + lineErrors[0][1] + ' ' + lineErrors[0][2]
  #   atom.workspaceView.statusBar.appendLeft('<span id="go-plus-status" class="inline-block">' + msg + '</span>')