import Path from "node:path"
import FS from "node:fs/promises"
import JSZip from "jszip"
import { LambdaClient, UpdateFunctionCodeCommand } from "@aws-sdk/client-lambda"
import Atlas, { bundle as atlasBundle } from "@dashkite/atlas"

bundle = ( entryPath, options = {} ) ->
  options.local ?= {}
  options.local.patterns ?= [ "**/.tempo/repos/**/*", "../**/*" ]
  atlasBundle entryPath, options

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
  bundle
  upload
  unbundle
}

export {
  bundle
  upload
  unbundle
}