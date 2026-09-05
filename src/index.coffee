import Path from "node:path"
import FS from "node:fs/promises"
import JSZip from "jszip"
import { LambdaClient, UpdateFunctionCodeCommand } from "@aws-sdk/client-lambda"
import { interpolate } from "@dashkite/joy/text"
import Atlas from "@dashkite/atlas"
import Generators from "@dashkite/atlas/generators"
import Local from "@dashkite/atlas/generators/local"
import presets from "./presets"

stripVersion = ( str ) ->
  atIndex = str.lastIndexOf "@"
  if atIndex > 0
    str.slice 0, atIndex
  else
    str

parsePackageTarget = ( target, defaultImporter = "" ) ->
  unversionedTarget = target.split("/").map(stripVersion).join("/").replace(/^\//, "")
  if target.indexOf("node_modules/") == -1
    return {
      isPackage: false
      path: target.replace(/^\//, "")
      unversionedTarget
      importer: defaultImporter
    }

  cleanTarget = target.replace /^\//, ""
  segments = cleanTarget.split(/\/node_modules\/|node_modules\//).filter Boolean
  leafSegment = segments[ segments.length - 1 ]

  if leafSegment.startsWith "@"
    parts = leafSegment.split "/"
    pkgWithVersion = parts.slice( 0, 2 ).join "/"
    relPath = parts.slice( 2 ).join "/"
  else
    parts = leafSegment.split "/"
    pkgWithVersion = parts[ 0 ]
    relPath = parts.slice( 1 ).join "/"

  atIndex = pkgWithVersion.lastIndexOf "@"
  if atIndex > 0
    specifier = pkgWithVersion.slice 0, atIndex
    version = pkgWithVersion.slice atIndex + 1
  else
    specifier = pkgWithVersion
    version = ""

  name = if specifier.startsWith "@" then specifier.split("/")[ 1 ] else specifier
  escapedSpecifier = specifier.replace /\//g, "+"

  importer = defaultImporter
  if segments.length > 1
    firstSegment = segments[ 0 ].replace /\/$/, ""
    firstPkgWithVersion = if firstSegment.startsWith "@"
      firstSegment.split("/").slice( 0, 2 ).join "/"
    else
      firstSegment.split("/")[ 0 ]
    cleanFirst = stripVersion firstPkgWithVersion
    importer = if cleanFirst.startsWith "@" then cleanFirst.split("/")[ 1 ] else cleanFirst

  {
    isPackage: true
    specifier
    name
    version
    escapedSpecifier
    path: relPath
    importer
    unversionedTarget
  }

entries = ( map ) ->
  return unless map?
  if map.imports?
    for specifier, target of map.imports
      yield { scope: "/", specifier, target }

  if map.scopes?
    for scope, mappings of map.scopes
      for specifier, target of mappings
        yield { scope, specifier, target }

deriveScopeBundleDirectory = ( scope ) ->
  if scope == "/"
    ""
  else
    scope.replace(/^\//, "").replace(/\/$/, "")

derivePackageSubpath = ( target ) ->
  marker = "node_modules/"
  index = target.lastIndexOf marker
  if index != -1
    target.slice index + marker.length
  else
    target.replace /^\//, ""

derivePackageBundleDirectory = ( filePath ) ->
  marker = "node_modules/"
  index = filePath.lastIndexOf marker
  return "" if index == -1

  prefix = filePath.slice 0, index + marker.length
  remainder = filePath.slice index + marker.length
  parts = remainder.split "/"

  packageName = if remainder.startsWith "@"
    parts.slice( 0, 2 ).join "/"
  else
    parts[ 0 ]

  Path.join prefix, packageName

transformEntry = ({ scope = "/", target }) ->
  target.split("/").map(stripVersion).join("/").replace(/^\//, "")

resolveSourcePath = ( root, target, defaultImporter = "", presetName = "pnpm:metarepo", scope = "/" ) ->
  importer = if scope? && scope != "/"
    scopeParsed = parsePackageTarget scope
    if scopeParsed.isPackage then scopeParsed.name else defaultImporter
  else
    defaultImporter

  parsed = parsePackageTarget target, importer
  unless parsed.isPackage
    return Path.resolve root, parsed.path

  context = parsed
  templateList = presets[ presetName ] ? presets[ "pnpm:metarepo" ]
  for template in templateList
    try
      rel = interpolate template, context
      candidate = Path.resolve root, rel
      await FS.access candidate
      return candidate

  # Fallback for npm: check packages nested inside root node_modules
  nmDir = Path.join root, "node_modules"
  try
    nmEntries = await FS.readdir nmDir, withFileTypes: true
    for entry in nmEntries
      if entry.isDirectory()
        candidate = Path.join nmDir, entry.name, "node_modules", parsed.specifier, parsed.path
        try
          await FS.access candidate
          return candidate
        catch
          continue
  catch

  if presetName == "pnpm:metarepo"
    parentDir = Path.dirname root
    try
      siblings = await FS.readdir parentDir
      for sibling in siblings
        siblingPath = Path.join parentDir, sibling
        pkgJsonPath = Path.join siblingPath, "package.json"
        try
          manifest = JSON.parse await FS.readFile pkgJsonPath, "utf8"
          if manifest.name == parsed.specifier
            candidate = Path.join siblingPath, parsed.path
            await FS.access candidate
            return candidate
        catch
          continue

      for sibling in siblings
        candidate = Path.join parentDir, sibling, "node_modules", parsed.specifier, parsed.path
        try
          await FS.access candidate
          return candidate
        catch
          null

        if parsed.version
          candidatePnpm = Path.join(
            parentDir
            sibling
            "node_modules"
            ".pnpm"
            "#{ parsed.escapedSpecifier }@#{ parsed.version }"
            "node_modules"
            parsed.specifier
            parsed.path
          )
          try
            await FS.access candidatePnpm
            return candidatePnpm
          catch
            null
    catch

  throw new Error "Cannot resolve source for #{ parsed.specifier }@#{ parsed.version } (#{ parsed.path }) from #{ root }"

findPackageManifest = ( filePath ) ->
  try
    realPath = await FS.realpath filePath
    directory = Path.dirname realPath
    while directory && directory != Path.dirname( directory )
      manifestPath = Path.join directory, "package.json"
      try
        await FS.access manifestPath
        return manifestPath
      catch
        directory = Path.dirname directory
  catch
    null

bundle = ( entryPath, options = {} ) ->
  cwd = options.cwd ? options.root
  relativeEntry = if cwd? && Path.isAbsolute entryPath
    Path.relative cwd, entryPath
  else
    entryPath

  preset = options.preset ? "pnpm:metarepo"
  defaultImporter = if cwd? then Path.basename( cwd ) else ""

  Generators.clear()
  Generators.register Local.make { options..., cwd }

  external = [ "@aws-sdk/*", ( options.external ? [] )... ]

  map = await Atlas.generate [ relativeEntry ], null, {
    options...
    cwd
    platform: "node"
    conditions: [ "node" ]
    external: external
  }

  root = cwd
  zip = new JSZip()
  visitedDestinations = new Set()
  visitedPackages = new Set()

  # Entry point
  entrySourcePath = if root? then Path.resolve( root, relativeEntry ) else relativeEntry
  zip.file relativeEntry, await FS.readFile( entrySourcePath )
  visitedDestinations.add relativeEntry

  # Root package.json if present
  rootPkgJson = if root? then Path.resolve( root, "package.json" ) else "package.json"
  try
    zip.file "package.json", await FS.readFile( rootPkgJson )
    visitedDestinations.add "package.json"

  for tuple from entries map
    destination = transformEntry tuple
    sourcePath = await resolveSourcePath root, tuple.target, defaultImporter, preset, tuple.scope

    packageBundleDirectory = derivePackageBundleDirectory destination
    if packageBundleDirectory != "" && !visitedPackages.has( packageBundleDirectory )
      visitedPackages.add packageBundleDirectory
      manifestSource = await findPackageManifest sourcePath
      if manifestSource?
        manifestDestination = Path.join packageBundleDirectory, "package.json"
        unless visitedDestinations.has manifestDestination
          visitedDestinations.add manifestDestination
          content = await FS.readFile manifestSource
          zip.file manifestDestination, content

    unless visitedDestinations.has destination
      visitedDestinations.add destination
      content = await FS.readFile sourcePath
      zip.file destination, content

  await zip.generateAsync
    type: "nodebuffer"
    compression: "DEFLATE"
    compressionOptions:
      level: 9

upload = ( functionName, zipBuffer, options = {} ) ->
  region = options.region || "us-east-1"
  lambda = new LambdaClient { region }
  await lambda.send new UpdateFunctionCodeCommand
    FunctionName: functionName
    ZipFile: zipBuffer
  undefined

unbundle = ( entryPath, targetDirectory, options = {} ) ->
  buffer = if Buffer.isBuffer entryPath
    entryPath
  else
    await bundle entryPath, options
  zip = await JSZip.loadAsync buffer
  for name, file of zip.files
    unless file.dir
      outputPath = Path.join targetDirectory, name
      await FS.mkdir Path.dirname( outputPath ), recursive: true
      content = await file.async "nodebuffer"
      await FS.writeFile outputPath, content

export default {
  entries
  deriveScopeBundleDirectory
  derivePackageSubpath
  derivePackageBundleDirectory
  transformEntry
  resolveSourcePath
  findPackageManifest
  bundle
  upload
  unbundle
}

export {
  entries
  deriveScopeBundleDirectory
  derivePackageSubpath
  derivePackageBundleDirectory
  transformEntry
  resolveSourcePath
  findPackageManifest
  bundle
  upload
  unbundle
}