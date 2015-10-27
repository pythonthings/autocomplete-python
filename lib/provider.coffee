{Disposable, CompositeDisposable, BufferedProcess} = require 'atom'
path = require 'path'
DefinitionsView = require './definitions-view'
filter = undefined

module.exports =
  selector: '.source.python'
  disableForSelector: '.source.python .comment, .source.python .string'
  inclusionPriority: 1
  suggestionPriority: 2
  excludeLowerPriority: true

  _possiblePythonPaths: ->
    if /^win/.test process.platform
      return ['C:\\Python2.7',
               'C:\\Python3.4',
               'C:\\Python3.5',
               'C:\\Program Files (x86)\\Python 2.7',
               'C:\\Program Files (x86)\\Python 3.4',
               'C:\\Program Files (x86)\\Python 3.5',
               'C:\\Program Files (x64)\\Python 2.7',
               'C:\\Program Files (x64)\\Python 3.4',
               'C:\\Program Files (x64)\\Python 3.5',
               'C:\\Program Files\\Python 2.7',
               'C:\\Program Files\\Python 3.4',
               'C:\\Program Files\\Python 3.5']
    else
      return ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']

  constructor: ->
    @requests = {}
    @definitionsView = null
    @snippetsManager = null

    pythonPath = atom.config.get('autocomplete-python.pythonPath')
    env = process.env
    path_env = (env.PATH or '').split path.delimiter
    path_env.unshift pythonPath if pythonPath and pythonPath not in path_env
    for p in @_possiblePythonPaths()
      if p not in path_env
        path_env.push p
    env.PATH = path_env.join path.delimiter

    @provider = new BufferedProcess
      command: atom.config.get('autocomplete-python.pythonExecutable'),
      args: [__dirname + '/completion.py'],
      options:
        env: env
      stdout: (data) =>
        @_deserialize(data)
      stderr: (data) ->
        if atom.config.get('autocomplete-python.outputProviderErrors')
          atom.notifications.addError(
            'autocomplete-python traceback output:', {
              detail: "#{data}",
              dismissable: true})
      exit: (code) =>
        console.warn('autocomplete-python:exit', code, @provider)
    @provider.onWillThrowError ({error, handle}) =>
      if error.code is 'ENOENT' and error.syscall.indexOf('spawn') is 0
        atom.notifications.addWarning(
          ["autocomplete-python unable to find python executable. Please set"
           "the path to python directory manually in the package settings and"
           "restart your editor"].join(' '), {
          detail: [error, "Current path config: #{env.PATH}"].join('\n'),
          dismissable: true})
        @dispose()
        handle()
      else
        throw error

    editorSelector = 'atom-text-editor[data-grammar~=python]'
    commandName = 'autocomplete-python:go-to-definition'
    atom.commands.add editorSelector, commandName, =>
      if @definitionsView
        @definitionsView.destroy()
      @definitionsView = new DefinitionsView()
      editor = atom.workspace.getActiveTextEditor()
      bufferPosition = editor.getCursorBufferPosition()
      @getDefinitions({editor, bufferPosition}).then (results) =>
        @definitionsView.setItems(results)
        if results.length == 1
          @definitionsView.confirmed(results[0])

    disposables = new CompositeDisposable()
    addEventListener = (editor, eventName, handler) ->
      editorView = atom.views.getView editor
      editorView.addEventListener eventName, handler
      new Disposable ->
        editor.removeEventListener eventName, handler
    atom.workspace.observeTextEditors (editor) =>
      if editor.getGrammar().scopeName == 'source.python'
        disposables.add addEventListener editor, 'keyup', (event) =>
          if event.shiftKey and event.keyCode == 57
            @_completeArguments(editor, editor.getCursorBufferPosition())

  _serialize: (request) ->
    return JSON.stringify(request)

  _sendRequest: (data, respawned) ->
    if @provider and @provider.process
      process = @provider.process
      if process.exitCode == null and process.signalCode == null
        return @provider.process.stdin.write(data + '\n')
      else if respawned
        atom.notifications.addWarning(
          ["Failed to spawn daemon for autocomplete-python."
           "Completions will not work anymore"
           "unless you restart your editor."].join(' '), {
          detail: ["exitCode: #{process.exitCode}"
                   "signalCode: #{process.signalCode}"].join('\n'),
          dismissable: true})
        @dispose()
      else
        @constructor()
        @_sendRequest(data, respawned: true)
        console.debug 'Re-spawning python process...'
    else
      console.debug 'Attempt to communicate with terminated process', @provider

  _deserialize: (response) ->
    response = JSON.parse(response)
    if response['arguments']
      editor = @requests[response['id']]
      if typeof editor == 'object'
        bufferPosition = editor.getCursorBufferPosition()
        # Compare response ID with current state to avoid stale completions
        if response['id'] == @_generateRequestId(editor, bufferPosition)
          @snippetsManager?.insertSnippet(response['arguments'], editor)
    else
      resolve = @requests[response['id']]
      if typeof resolve == 'function'
        resolve(response['results'])
    delete @requests[response['id']]

  _generateRequestId: (editor, bufferPosition) ->
    return require('crypto').createHash('md5').update([
      editor.getPath(), editor.getText(), bufferPosition.row,
      bufferPosition.column].join()).digest('hex')

  _generateRequestConfig: ->
    extraPaths = []
    for p in atom.config.get('autocomplete-python.extraPaths').split(';')
      for project in atom.project.getPaths()
        modified = p.replace('$PROJECT', project)
        if modified not in extraPaths
          extraPaths.push(modified)
    args =
      'extraPaths': extraPaths
      'useSnippets': atom.config.get('autocomplete-python.useSnippets')
      'caseInsensitiveCompletion': atom.config.get(
        'autocomplete-python.caseInsensitiveCompletion')
      'showDescriptions': atom.config.get(
        'autocomplete-python.showDescriptions')
    return args

  setSnippetsManager: (@snippetsManager) ->

  _completeArguments: (editor, bufferPosition) ->
    if atom.config.get('autocomplete-python.useSnippets') == 'none'
      return
    payload =
      id: @_generateRequestId(editor, bufferPosition)
      lookup: 'arguments'
      path: editor.getPath()
      source: editor.getText()
      line: bufferPosition.row
      column: bufferPosition.column
      config: @_generateRequestConfig()

    @_sendRequest(@_serialize(payload))
    return new Promise =>
      @requests[payload.id] = editor

  getSuggestions: ({editor, bufferPosition, scopeDescriptor, prefix}) ->
    if prefix not in ['.', ' '] and (prefix.length < 1 or /\W/.test(prefix))
      return []
    # we want to do our own filtering, hide any existing prefix from Jedi
    line = editor.getTextInRange([[bufferPosition.row, 0], bufferPosition])
    lastIdentifier = /[a-zA-Z_][a-zA-Z0-9_]*$/.exec(line)
    col = if lastIdentifier then lastIdentifier.index else bufferPosition.column
    payload =
      id: @_generateRequestId(editor, bufferPosition)
      lookup: 'completions'
      path: editor.getPath()
      source: editor.getText()
      line: bufferPosition.row
      column: col
      config: @_generateRequestConfig()

    @_sendRequest(@_serialize(payload))
    return new Promise (resolve) =>
      @requests[payload.id] = (matches) ->
        if matches.length isnt 0 and prefix isnt '.'
          filter ?= require('fuzzaldrin').filter
          matches = filter(matches, prefix, key: 'snippet')
        resolve(matches)

  getDefinitions: ({editor, bufferPosition}) ->
    payload =
      id: @_generateRequestId(editor, bufferPosition)
      lookup: 'definitions'
      path: editor.getPath()
      source: editor.getText()
      line: bufferPosition.row
      column: bufferPosition.column
      config: @_generateRequestConfig()

    @_sendRequest(@_serialize(payload))
    return new Promise (resolve) =>
      @requests[payload.id] = resolve

  dispose: ->
    @provider.kill()
