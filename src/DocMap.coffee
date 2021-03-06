# A map of documents. Useful for caching documents to avoid hitting the collection.
class DocMap

  constructor: (options) ->
    @_options = Setter.merge({
      # Whether to freeze all documents added to the temporary collection/map to ensure
      # immutability for direct access (faster).
      freeze: true
      # Whether to use a plain map instead of a temporary collection. Faster since nothing needs
      # to be cloned, but is not reactive and selectors cannot be used on the underlying collection.
      plain: false
    }, options)
    @_collection = if @_options.plain then {} else Collections.createTemporary()
    @_handles = []

  # Adds the given documents to the map.
  #   * `arg` - A cursor, collection, array or document.
  #   * `options.beforeInsert` - A function which is passed each document in the given cursor before
  #         it is inserted into the collection. If false is returned by this function, the
  #         insert is cancelled. Only used if the first argument is a colleciton or cursor.
  add: (arg, options) ->
    if Collections.isCursor(arg) or Collections.isCollection(arg)
      if @_options.plain
        return _.map Collections.getItems(arg), (doc) => @_insert(doc)
      else
        promise = Collections.copy arg, @_collection,
          track: true
          beforeInsert: options?.beforeInsert
          afterInsert: (id) => @_maybeFreeze @get(id)
        @_handles.push @_collection.trackHandle
        return promise
    else if Types.isArray(arg)
      return _.map arg, (doc) => @_insert(doc)
    else if Types.isObjectLiteral(arg)
      return @_insert(arg)
    else
      throw new Error('Unsupported type - must be doc or cursor')

  _insert: (doc) ->
    if @_options.plain
      id = doc._id
      unless id then throw new Error('Inserted doc in plain map must have ID')
      @_collection[id] = doc
    else
      id = @_collection.insert(doc)
    @_maybeFreeze @get(id)
    return id

  _maybeFreeze: (doc) -> if @_options.freeze then Object.freeze(doc) else doc

  get: (id) -> if @_options.plain then @_collection[id] else @_collection._collection._docs.get(id)

  getAll: -> _.values @_getMap()

  getMap: -> _.extend {}, @_getMap()

  _getMap: -> if @_options.plain then @_collection else @_collection._collection._docs._map

  forEach: (callback) -> _.each @_getMap(), callback
  
  has: (id) -> if @_options.plain then @_collection[id]? else @_collection._collection._docs.has(id)

  remove: (selectorOrId) ->
    if @_options.plain
      if @has(selectorOrId)
        delete @_collection[selectorOrId]
        1
      else 0
    else
      # TODO(aramk) Will still recieve updates from copy() even if document is removed here.
      @_collection.remove(selectorOrId)

  size: -> if @_options.plain then _.size(@_collection) else @_collection._collection._docs.size()

  getCollection: -> unless @_options.plain then @_collection

  # Wraps methods on the given collection to use the DocMap as a cache
  wrapCollection: (collection) ->
    unless collection then throw new Error('No collection to wrap')
    if @_options.freeze then throw new Error('Cannot wrap collection which is frozen - will cause
        findOne() result to be unexpectedly frozen')

    collection._findOne = collection.findOne
    collection.findOne = (selector, options) =>
      options ?= {}
      options.collection = collection
      @findOne(selector, options)

  findOne: (selector, options) =>
    usedCache = true
    findSelector = selector
    collection = options?.collection ? @getCollection()

    if Types.isString(selector)
      doc = @get(selector)
      findSelector = {_id: selector}
    else if Types.isObjectLiteral(selector) and selector._id?
      doc = @get(selector._id)
    else
      useCache = false

    # If the doc wasn't found in the cache, or an ID wasn't provided, attempt to find in the
    # collection.
    # TODO(aramk) This won't actually be used for when plain = true, since there's no collection.
    if (!doc or !useCache) and collection
      # Use _findOne() if using wrapCollection.
      doc = (collection._findOne ? collection.findOne).apply(collection, arguments)
      useCache = false

    if Tracker.active and usedCache and collection
      # Create reactive dependency if necessary but avoid calling fetch() which is slower.
      cursor = collection.find.call(collection, findSelector, options)
      if cursor.reactive
        cursor._depend
          addedBefore: true
          removed: true
          changed: true
          movedBefore: true

    return doc

  reset: -> _.each @_handles, (handle) -> handle.stop()

  destroy: ->
    # TODO(aramk) Add any destructive logic here.
    @reset()
