import FS from "node:fs/promises"
import Path from "node:path"
import JSZip from "jszip"
import esbuild from "esbuild"
import { LambdaClient, UpdateFunctionCodeCommand } from "@aws-sdk/client-lambda"

normalize = ( path ) ->
  if path[0] == "/" || path[0] == "."
    path
  else
    "./#{ path }"
  

cache = {}

read = ( path ) ->
  ( cache[ path ] ?= await ( FS.readFile path, "utf8" ) )

exists = ( path ) ->
  try
    await ( read path )
    true
  catch
    false

extension = ( ext, path ) ->
  ( Path.join ( Path.dirname path ),
    ( Path.basename path, ( Path.extname path ) ) + ext )

findPackageRoot = ( directory ) ->
  if await ( exists ( Path.join directory, "package.json" ) )
    directory
  else
    parent = ( Path.dirname directory )
    if parent == directory then null else await ( findPackageRoot parent )

getPackage = ( root ) ->
  source = ( Path.join root, "package.json" )
  text = await ( read source )
  data = ( JSON.parse text )
  { source, data }

getModule = ( source, buildDirectory ) ->
  resolvedSource = ( Path.resolve source )
  cwd = ( Path.resolve "." )
  
  root = await ( findPackageRoot ( Path.dirname resolvedSource ) )
  throw new Error "Could not find package.json for #{ source }" if ! root?
  
  _package = await ( getPackage root )
  local = root == cwd

  target = if local
    ( Path.relative cwd, resolvedSource )
  else
    ( Path.join "node_modules", _package.data.name,
      ( Path.relative root, resolvedSource ) )

  _package.target = if local
    "package.json"
  else
    ( Path.join "node_modules", _package.data.name, "package.json" )

  { source, root, local, target, package: _package }

bundle = ( entryPath ) ->
  absoluteEntry = ( Path.resolve entryPath )
  buildDirectory = ( Path.dirname absoluteEntry )

  zip = new JSZip

  { metafile } = await ( esbuild.build
    entryPoints: [ absoluteEntry ]
    bundle: true
    sourcemap: false
    platform: "node"
    conditions: [ "node" ]
    outfile: "/dev/null"
    external: [ "@aws-sdk/*" ]
    metafile: true
    absWorkingDir: process.cwd()
  )

  filePackages = {}
  packageMetadata = {}
  for file, _ of metafile.inputs
    resolvedFile = ( Path.resolve file )
    root = await ( findPackageRoot ( Path.dirname resolvedFile ) )
    if root?
      _package = await ( getPackage root )
      filePackages[ resolvedFile ] = { root, package: _package }
      packageMetadata[ root ] = _package

  cwd = ( Path.resolve "." )
  packageImporters = {}

  for file, input of metafile.inputs
    resolvedFile = ( Path.resolve file )
    filePkg = filePackages[ resolvedFile ]
    continue if ! filePkg?

    for imp in ( input.imports || [] )
      resolvedImp = ( Path.resolve imp.path )
      impPkg = filePackages[ resolvedImp ]
      continue if ! impPkg?

      if impPkg.root != filePkg.root
        packageImporters[ impPkg.root ] ?= new Set
        packageImporters[ impPkg.root ].add filePkg.root

  packageTargets = {}
  packageTargets[ cwd ] = [ "" ]

  resolvePaths = ( pkgRoot ) ->
    return packageTargets[ pkgRoot ] if packageTargets[ pkgRoot ]?

    importers = packageImporters[ pkgRoot ]
    if ! importers? || importers.size == 0
      pkgName = packageMetadata[ pkgRoot ]?.data?.name
      return packageTargets[ pkgRoot ] = [ ( Path.join "node_modules", pkgName ) ]

    paths = []
    for importerRoot in Array.from( importers )
      parentPaths = ( await resolvePaths importerRoot )
      pkgName = packageMetadata[ pkgRoot ]?.data?.name
      for parentPath in parentPaths
        paths.push ( Path.join parentPath, "node_modules", pkgName )
    packageTargets[ pkgRoot ] = paths

  for file, filePkg of filePackages
    await ( resolvePaths filePkg.root )

  for file, _ of metafile.inputs
    resolvedFile = ( Path.resolve file )
    filePkg = filePackages[ resolvedFile ]
    continue if ! filePkg?

    targets = packageTargets[ filePkg.root ]
    for targetPkgDirectory in targets
      relPath = ( Path.relative filePkg.root, resolvedFile )
      targetFile = ( Path.join targetPkgDirectory, relPath )
      ( zip.file targetFile, await ( read resolvedFile ) )

      targetPkgJson = ( Path.join targetPkgDirectory, "package.json" )
      ( zip.file targetPkgJson, await ( read filePkg.package.source ) )

  await ( zip.generateAsync
    type: "nodebuffer"
    compression: "DEFLATE"
    compressionOptions:
      level: 9
  )

upload = ( functionName, zipBuffer, options = {} ) ->
  region = options.region || "us-east-1"
  lambda = new LambdaClient { region }
  await ( lambda.send new UpdateFunctionCodeCommand
    FunctionName: functionName
    ZipFile: zipBuffer
  )
  undefined

unbundle = ( entryPath, targetDirectory ) ->
  buffer = await ( bundle entryPath )
  zip = await ( JSZip.loadAsync buffer )
  for name, file of zip.files
    if ! file.dir
      outputPath = ( Path.join targetDirectory, name )
      await ( FS.mkdir ( Path.dirname outputPath ), recursive: true )
      content = await ( file.async "nodebuffer" )
      await ( FS.writeFile outputPath, content )
  undefined

export { bundle, upload, unbundle, getModule }