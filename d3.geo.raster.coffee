quadTiles = require './d3.quadTiles'

# Copyright 2014, Jason Davies, http://www.jasondavies.com/

prefixMatch = (p) ->
  for prefix in p
    if "#{prefix}Transform" of document.body.style
      return "-#{prefix}-"
  ''

# Check for vendor prefixes, by Mike Bostock.
prefix = prefixMatch ['webkit', 'ms', 'Moz', 'O']

key = (d) -> d.key.join ', '

pixel = (d) -> (d | 0) + 'px'

# Find latitude based on Mercator y-coordinate (in degrees).
mercatorPhi = (y) -> Math.atan(Math.exp(-y * Math.PI / 180)) * 360 / Math.PI - 90
mercatorPhi.invert = (Phi) ->
  -Math.log(Math.tan(Math.PI * .25 + Phi * Math.PI / 360)) * 180 / Math.PI

bilinear = (f) ->
  (x, y, o) ->
    x0 = Math.floor(x)
    y0 = Math.floor(y)
    x1 = Math.ceil(x)
    y1 = Math.ceil(y)
    if x0 == x1 or y0 == y1
      return f(x0, y0, o)
    (f(x0, y0, o) * (x1 - x) * (y1 - y) + f(x1, y0, o) * (x - x0) * (y1 - y) + f(x0, y1, o) * (x1 - x) * (y - y0) + f(x1, y1, o) * (x - x0) * (y - y0)) / ((x1 - x0) * (y1 - y0))

urlTemplate = (s) ->
  (o) ->
    s.replace /\{([^\}]+)\}/g, (_, d) ->
      v = o[d]
      if v != null then v else d == 'quadkey' and quadkey(o.x, o.y, o.z)

quadkey = (column, row, zoom) ->
  `var key`
  key = []
  while i <= zoom
    key.push (row >> zoom - i & 1) << 1 | column >> zoom - i & 1
    i++
  key.join ''

module.exports = d3.geo.raster = (projection) ->
  path = d3.geo.path().projection(projection)
  url = null
  scaleExtent = [0, Infinity]
  subdomains = ['a', 'b', 'c', 'd']
  tms = false
  reprojectDispatch = d3.dispatch 'reprojectcomplete'
  imgCanvas = document.createElement 'canvas'
  imgContext = imgCanvas.getContext '2d'

  redraw = (layer) ->
    # TODO improve zoom level computation
    z = Math.max(scaleExtent[0], Math.min(scaleExtent[1], (Math.log(projection.scale()) / Math.LN2 | 0) - 6))
    pot = z + 6
    ds = projection.scale() / Math.pow 2, pot
    t = projection.translate()
    layer.style prefix + 'transform', 'translate(' + t.map(pixel) + ')scale(' + ds + ')'
    tile = layer.selectAll('.tile').data(quadTiles(projection, z), key)
    tile.enter()
      .append('canvas')
      .attr('class', 'tile')
      .each((d) ->
        canvas = this
        image = d.image = new Image
        k = d.key
        image.crossOrigin = true

        image.onload = ->
          setTimeout (-> onload d, canvas, pot), 1

        y = k[1]
        y = 2 ** z - y - 1 if tms
        image.src = url
          x: k[0]
          y: y
          z: k[2]
          subdomain: subdomains[(k[0] * 31 + k[1]) % subdomains.length]
      )
      .transition().delay(500).each 'end', ->
        reprojectDispatch.reprojectcomplete()
    tile.exit().remove()

  onload = (d, canvas, pot) ->
    t = projection.translate()
    s = projection.scale()
    c = projection.clipExtent()
    image = d.image
    dx = image.width
    dy = image.height
    k = d.key
    width = Math.pow 2, k[2]
    projection.translate([0, 0]).scale(1 << pot).clipExtent null
    imgCanvas.width = dx
    imgCanvas.height = dy
    imgContext.drawImage image, 0, 0, dx, dy
    bounds = path.bounds(d)
    x0 = d.x0 = bounds[0][0] | 0
    y0 = d.y0 = bounds[0][1] | 0
    x1 = bounds[1][0] + 1 | 0
    y1 = bounds[1][1] + 1 | 0
    Lambda0 = k[0] / width * 360 - 180
    Lambda1 = (k[0] + 1) / width * 360 - 180
    Phi0 = k[1] / width * 360 - 180
    Phi1 = (k[1] + 1) / width * 360 - 180
    mPhi0 = mercatorPhi(Phi0)
    mPhi1 = mercatorPhi(Phi1)
    width = canvas.width = x1 - x0
    height = canvas.height = y1 - y0
    context = canvas.getContext('2d')
    if width > 0 and height > 0
      sourceData = imgContext.getImageData(0, 0, dx, dy).data
      target = context.createImageData(width, height)
      targetData = target.data
      interpolate = bilinear((x, y, offset) ->
        sourceData[(y * dx + x) * 4 + offset]
      )
      y = y0
      i = -1
      while y < y1
        x = x0
        while x < x1
          p = projection.invert [x, y]
          Lambda = undefined
          Phi = undefined
          if !p or isNaN(Lambda = p[0]) or isNaN(Phi = p[1]) or Lambda > Lambda1 or Lambda < Lambda0 or Phi > mPhi0 or Phi < mPhi1
            i += 4
            ++x
            continue
          Phi = mercatorPhi.invert(Phi)
          sx = (Lambda - Lambda0) / (Lambda1 - Lambda0) * dx
          sy = (Phi - Phi0) / (Phi1 - Phi0) * dy
          if 1
            q = (((Lambda - Lambda0) / (Lambda1 - Lambda0) * dx | 0) + ((Phi - Phi0) / (Phi1 - Phi0) * dy | 0) * dx) * 4
            targetData[++i] = sourceData[q]
            targetData[++i] = sourceData[++q]
            targetData[++i] = sourceData[++q]
          else
            targetData[++i] = interpolate(sx, sy, 0)
            targetData[++i] = interpolate(sx, sy, 1)
            targetData[++i] = interpolate(sx, sy, 2)
          targetData[++i] = 0xff
          ++x
        ++y
      context.putImageData target, 0, 0
    d3.selectAll([canvas])
      .style('left', x0 + 'px')
      .style 'top', y0 + 'px'
    projection.translate(t).scale(s).clipExtent c

  redraw.url = (_) ->
    return url unless arguments.length
    url = if typeof _ == 'string' then urlTemplate(_) else _
    redraw

  redraw.scaleExtent = (_) ->
    return scaleExtent unless arguments.length
    scaleExtent = _
    redraw

  redraw.tms = (_) ->
    return tms unless arguments.length
    tms = _
    redraw

  redraw.subdomains = (_) ->
    return subdomains unless arguments.length
    subdomains = _
    redraw

  d3.rebind redraw, reprojectDispatch, 'on'
  redraw

module.exports.prefix = prefix