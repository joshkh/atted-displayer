request = require 'superagent'
_ = require 'underscore'
Q = require 'q'
style = require('./styles/app.css');
Spinner = require 'spin'
$ = require 'jquery'
mediator = require './utils/Events'
Handlebars = require 'hbsfy/runtime'

class App
  constructor: (@opts, @callback, @queryhook) ->

    # Execute our prehook, if it exists.
    @opts.origcutoff = @opts.cutoff
    @defaultopts = _.clone @opts

    @currentcutoff = 0

    if !@opts.cutoff then @opts.cutoff = 20
    if !@opts.method then @opts.method = 'mr'

    # Listener: Switching score types:
    mediator.subscribe "switch-score", =>
      cutoff = $("#{@opts.target} > div.toolbar > div.toolcontrols > input.cutoff");
      if cutoff.val()? and cutoff.val() != "" then @opts.origcutoff = cutoff.val() else @opts.origcutoff = @defaultopts.origcutoff
      if cutoff.val()? and cutoff.val() != "" then @opts.cutoff = cutoff.val() else @opts.cutoff = @defaultopts.cutoff
      if cutoff.length > 0 then @requery @opts, false

    mediator.subscribe "load-defaults", =>
      textCutoff = $("#{@opts.target} > div.toolbar > div.toolcontrols input.cutoff");
      textCutoff.val(@defaultopts.origcutoff)

      # @requery {method: @opts.method, cutoff: @opts.cutoff}
      @requery @defaultopts, true

    # Fetch our loading template
    template = require("./templates/shell.hbs");

    # Render the shell of the application
    $(@opts.target).html template {}

    toolbartemplate = require './templates/tools.hbs'

    $("#{@opts.target} > div.toolbar").html toolbartemplate {opts: @opts, mediator: mediator}
    textCutoff = $("#{@opts.target} > div.toolbar > div.toolcontrols input.cutoff");
    textCutoff.val(@opts.cutoff)

    $('.reload').on "click", ()->
      mediator.publish "switch-score"

    $('.defaults').on "click", ()->
      mediator.publish "load-defaults"

    # Options for the spinner:
    @spinneropts =
      lines: 13 # The number of lines to draw
      length: 10 # The length of each line
      width: 6 # The line thickness
      radius: 20 # The radius of the inner circle
      corners: 1 # Corner roundness (0..1)
      rotate: 0 # The rotation offset
      direction: 1 # 1: clockwise, -1: counterclockwise
      color: "#000" # #rgb or #rrggbb or array of colors
      speed: 1 # Rounds per second
      trail: 60 # Afterglow percentage
      shadow: false # Whether to render a shadow
      hwaccel: false # Whether to use hardware acceleration
      className: "spinner" # The CSS class to assign to the spinner
      zIndex: 2e9 # The z-index (defaults to 2000000000)
      top: "100%" # Top position relative to parent
      left: "100%" # Left position relative to parent

    # Get the spinner container from the loading template
    @loadingtarget = $ '#searching_spinner_center'
    @wrapper = $("#{@opts.target} > div.atted-table-wrapper")
    @loadingmessage = $("#{@opts.target} > div.atted-table-wrapper > div.atted-loading-message")
    @spinel = @wrapper.find(".searching_spinner_center")

    # target = document.getElementById "searching_spinner_center"
    @spinner = new Spinner(@spinneropts).spin(@spinel[0]);
    @loadingmessage.show()
    @lastoptions = @opts

    # Execute our pre-query hook, if it exists.
    if @queryhook? then do @queryhook

    Q.when(@call(@opts, null, true))
      .then @getResolutionJob
      .then @waitForResolutionJob
      .then @fetchResolutionJob
      .then (results) =>
        @resolvedgenes = results.body.results.matches.MATCH

        @resolvedgenes = _.map @resolvedgenes, (gene) =>
          gene.score = @scoredict[gene.summary.primaryIdentifier]
          return gene

        do @renderapp

  getResolutionJob: (genes) =>
    deferred = Q.defer()

    # Pluck the gene names from our ATTED results
    ids = _.pluck @allgenes, "other_id"

    # Build our POST data
    payload =
      identifiers: ids
      type: "Gene"
      caseSensitive: true
      wildCards: true

    url = @opts.service + "/ids"

    # Submit an ID Resolution Job
    request
      .post(url)
      .send(payload)
      .then (response) =>
        deferred.resolve response.body

    deferred.promise

  waitForResolutionJob: (resolutionJob, deferred) =>
    url = @opts.service + "/ids/#{resolutionJob.uid}/status"

    deferred ?= Q.defer()

    request
      .get(url)
      .then (response) =>
        if response.body.status is "RUNNING"
          setTimeout (=>
            @waitForResolutionJob(resolutionJob, deferred)
            return
          ), 1000
        else if response.body.status is "SUCCESS"
          deferred.resolve resolutionJob

    deferred.promise

  fetchResolutionJob: (resolutionJob) =>

# Get our resolution results
    deferred = Q.defer()

    url = @opts.service + "/ids/#{resolutionJob.uid}/results"
    request
      .get(url)
      .then (response) =>
        deferred.resolve response
        @deleteResolutionJob resolutionJob

    deferred.promise

  deleteResolutionJob: (resolutionJob) =>
    url = @opts.service + "/ids/#{resolutionJob.uid}"
    request
      .del(url)

  requery: (options, autocutoff) ->
    # Execute our pre-query hook, if it exists.
    if @queryhook? then do @queryhook

    @loadingmessage.show()

    @table = @wrapper.find(".atted-table")
    @table.hide()
    $(@opts.target).find(".statsmessage").html("Querying ATTED service...")

    @lastoptions = options

    Q.when(@call(options, null, autocutoff))
      .then @getResolutionJob
      .then @waitForResolutionJob
      .then @fetchResolutionJob
      .then (results) =>
        @resolvedgenes = results.body.results.matches.MATCH
        @resolvedgenes = _.map @resolvedgenes, (gene) =>
          gene.score = @scoredict[gene.summary.primaryIdentifier]
          return gene
        do @renderapp

  call: (options, deferred, autocutoff) =>
    # @lastoptions = options
    @calculatedoptions = options

    options.guarantee ?= 1
    @currentcutoff = options.cutoff

    # Create our deferred object, later to be resolved
    deferred ?= Q.defer()

    # The URL of our web service
    titleAGICode = @opts.AGIcode[0].toUpperCase() + @opts.AGIcode.substr(1).toLowerCase()
    url = @opts.atted + "/#{titleAGICode}/#{options.cutoff}"

    # Make a request to the web service
    request.get(url).then (response) =>
      @allgenes = response.body.result_set[0].results
      @scoredict = {}

      _.each @allgenes, (geneObj) =>
        @scoredict[geneObj.other_id] = geneObj.logit_score

      deferred.resolve true

    # Return our promise
    deferred.promise

  talkValues: (extent, values, total) ->
    opts =
      lowest: if values.length < 1 then 0 else values[0].score
      highest: if values.length < 1 then 0 else values[values.length - 1].score

    template = require("./templates/selected.hbs")

    $("#{@opts.target} > div.stats").html template {values: values, opts: opts, total: total}

    # $('#stats').html template {values: values, opts: opts}
    @rendertable(values)

  filter: (score) ->
    cutoff = _.filter @allgenes, (gene) ->
      gene.score <= score

    @rendertable cutoff

  renderapp: =>
    @wrapper.find(".atted-table").show()
    @loadingmessage.hide()
    @rendertable @resolvedgenes

    newarr = []

    _.each @resolvedgenes, (next) =>
      newarr.push next.summary.primaryIdentifier

    @callback(newarr)

  rendertable: (genes) =>
    if genes.length < 1

      template = require './templates/noresults.hbs'
      $("#{@opts.target} > div.atted-table-wrapper").html template {}


    else
      # Check to see if the table needs to be added
      table = $("#{@opts.target} > div.atted-table-wrapper > table.atted-table")

      if !table.length then $("#{@opts.target} > div.atted-table-wrapper").html("<table class='atted-table collection-table'></table>")

      template = require './templates/table.hbs'

      max = _.max genes, (gene) ->
        gene.score

      genes = _.sortBy genes, (item) ->
        if max.score < 1
          item.score
        else
          -item.score

      $("#{@opts.target} > div.atted-table-wrapper > table.atted-table").html template {genes: genes}

    if @opts.cutoff isnt @opts.origcutoff
      $(@opts.target).find(".statsmessage").html("<strong>#{genes.length}</strong> genes found with a score <strong>>= #{@currentcutoff} (Cutoff has been automatically reduced to guarantee results.)</strong>")
    else
      if @opts.method.toUpperCase() is "COR"
        $(@opts.target).find(".statsmessage").html("<strong>#{genes.length}</strong> genes found with a score <strong>>= #{@currentcutoff}</strong>")
      else
        $(@opts.target).find(".statsmessage").html("<strong>#{genes.length}</strong> genes found with a score <strong><= #{@currentcutoff}</strong>")

module.exports = App
