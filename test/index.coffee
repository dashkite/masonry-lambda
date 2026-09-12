import FS from "node:fs/promises"
import Path from "node:path"
import OS from "node:os"
import assert from "@dashkite/assert"
import { test, success } from "@dashkite/amen"
import print from "@dashkite/amen-console"
import JSZip from "jszip"
import { bundle, unbundle } from "../src/index"

dynamicImport = ( filePath ) ->
  ( new Function "filePath", "return import(filePath)" ) ( "file://" + filePath )

do ->

  print await test "Masonry Lambda", [

    test "bundle and unbundle simple application fixture", ->
      fixtureDirectory = "test/fixtures/simple-app"

      buffer = await bundle "src/index.js", root: fixtureDirectory
      zip = await JSZip.loadAsync buffer
      files = Object.keys zip.files

      assert files.includes "src/index.js"
      assert files.includes "src/helper.js"
      assert files.includes "package.json"
      assert files.includes "node_modules/math-lib/index.js"
      assert files.includes "node_modules/math-lib/package.json"

      temporaryDirectory = await FS.mkdtemp Path.join OS.tmpdir(), "masonry-simple-"
      try
        await unbundle buffer, temporaryDirectory
        { run } = await dynamicImport Path.join temporaryDirectory, "src/index.js"
        assert.equal 43, run()
      finally
        await FS.rm temporaryDirectory, recursive: true, force: true

    test "bundle and unbundle nested multi-version application fixture (npm)", ->
      nestedDirectory = "test/fixtures/nested-app"

      nestedBuffer = await bundle "src/index.js", root: nestedDirectory
      nestedZip = await JSZip.loadAsync nestedBuffer
      nestedFiles = Object.keys nestedZip.files

      assert nestedFiles.includes "src/index.js"
      assert nestedFiles.includes "package.json"
      assert nestedFiles.includes "node_modules/pkg-a/index.js"
      assert nestedFiles.includes "node_modules/pkg-a/package.json"
      assert nestedFiles.includes "node_modules/pkg-b/index.js"
      assert nestedFiles.includes "node_modules/pkg-b/package.json"
      assert nestedFiles.includes "node_modules/pkg-a/node_modules/shared-dep/index.js"
      assert nestedFiles.includes "node_modules/pkg-a/node_modules/shared-dep/package.json"
      assert nestedFiles.includes "node_modules/pkg-b/node_modules/shared-dep/index.js"
      assert nestedFiles.includes "node_modules/pkg-b/node_modules/shared-dep/package.json"

      temporaryDirectoryNested = await FS.mkdtemp Path.join OS.tmpdir(), "masonry-nested-"
      try
        await unbundle nestedBuffer, temporaryDirectoryNested
        { run } = await dynamicImport Path.join temporaryDirectoryNested, "src/index.js"
        result = run()
        assert.deepEqual { a: "pkg-a:v1", b: "pkg-b:v2" }, result
      finally
        await FS.rm temporaryDirectoryNested, recursive: true, force: true

  ]

  process.exit if success then 0 else 1
