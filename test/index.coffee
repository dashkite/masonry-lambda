import FS from "node:fs/promises"
import Path from "node:path"
import OS from "node:os"
import assert from "@dashkite/assert"
import { test, success } from "@dashkite/amen"
import print from "@dashkite/amen-console"
import JSZip from "jszip"
import {
  entries
  deriveScopeBundleDirectory
  derivePackageSubpath
  derivePackageBundleDirectory
  transformEntry
  resolveSourcePath
  findPackageManifest
  bundle
  unbundle
} from "../src/index"

toArray = ( iterable ) ->
  Array.from iterable

dynamicImport = ( filePath ) ->
  ( new Function "filePath", "return import(filePath)" ) ( "file://" + filePath )

do ->

  print await test "Masonry Lambda", [

    test "entries generator yields scope, specifier, target tuples", ->

      # 1. Root imports
      map1 =
        imports:
          "math-lib": "/node_modules/math-lib/index.js"
          "./helper.js": "/src/helper.js"

      result1 = toArray entries map1
      assert.deepEqual [
        { scope: "/", specifier: "math-lib", target: "/node_modules/math-lib/index.js" }
        { scope: "/", specifier: "./helper.js", target: "/src/helper.js" }
      ], result1

      # 2. Scoped imports
      map2 =
        scopes:
          "/node_modules/pkg-a/":
            "shared-dep": "/node_modules/shared-dep@1.0.0/index.js"
          "/node_modules/pkg-b/":
            "shared-dep": "/node_modules/shared-dep@2.0.0/index.js"

      result2 = toArray entries map2
      assert.deepEqual [
        { scope: "/node_modules/pkg-a/", specifier: "shared-dep", target: "/node_modules/shared-dep@1.0.0/index.js" }
        { scope: "/node_modules/pkg-b/", specifier: "shared-dep", target: "/node_modules/shared-dep@2.0.0/index.js" }
      ], result2

      # 3. Combined imports and scopes
      map3 =
        imports:
          "pkg-a": "/node_modules/pkg-a/index.js"
        scopes:
          "/node_modules/pkg-a/":
            "dep-x": "/node_modules/dep-x@1.0.0/index.js"

      result3 = toArray entries map3
      assert.deepEqual [
        { scope: "/", specifier: "pkg-a", target: "/node_modules/pkg-a/index.js" }
        { scope: "/node_modules/pkg-a/", specifier: "dep-x", target: "/node_modules/dep-x@1.0.0/index.js" }
      ], result3

      # 4. Empty / null map
      assert.deepEqual [], toArray entries null
      assert.deepEqual [], toArray entries {}

    test "deriveScopeBundleDirectory derives bundle directory for scopes", ->
      assert.equal "", deriveScopeBundleDirectory "/"
      assert.equal "node_modules/package-a",
        deriveScopeBundleDirectory "/node_modules/package-a/"
      assert.equal "node_modules/@dashkite/panama",
        deriveScopeBundleDirectory "/node_modules/@dashkite/panama/"
      assert.equal "node_modules/package-a/node_modules/shared-dependency",
        deriveScopeBundleDirectory "/node_modules/package-a/node_modules/shared-dependency/"

    test "derivePackageSubpath derives package subpath from targets", ->
      assert.equal "math-library/index.js",
        derivePackageSubpath "/node_modules/math-library/index.js"
      assert.equal "@dashkite/dolores/build/node/src/secrets.js",
        derivePackageSubpath "/node_modules/@dashkite/dolores/build/node/src/secrets.js"
      assert.equal "shared-dependency/index.js",
        derivePackageSubpath "/node_modules/package-a/node_modules/shared-dependency/index.js"
      assert.equal "src/helper.js",
        derivePackageSubpath "/src/helper.js"

    test "derivePackageBundleDirectory derives enclosing package directory", ->
      assert.equal "node_modules/math-library",
        derivePackageBundleDirectory "node_modules/math-library/index.js"
      assert.equal "node_modules/@dashkite/dolores",
        derivePackageBundleDirectory "node_modules/@dashkite/dolores/build/node/src/secrets.js"
      assert.equal "node_modules/package-a/node_modules/shared-dependency",
        derivePackageBundleDirectory "node_modules/package-a/node_modules/shared-dependency/index.js"
      assert.equal "node_modules/package-a/node_modules/@scope/package-b",
        derivePackageBundleDirectory "node_modules/package-a/node_modules/@scope/package-b/lib/index.js"
      assert.equal "",
        derivePackageBundleDirectory "src/helper.js"

    test "transformEntry maps single entry tuple to destination bundle path", ->

      # 1. Root bare import with version
      assert.equal "node_modules/math-library/index.js",
        transformEntry
          scope: "/"
          specifier: "math-library"
          target: "/node_modules/math-library@1.0.0/index.js"

      # 2. Root subpath bare import with version
      assert.equal "node_modules/@dashkite/dolores/build/node/src/secrets.js",
        transformEntry
          scope: "/"
          specifier: "@dashkite/dolores/secrets"
          target: "/node_modules/@dashkite/dolores@1.0.0/build/node/src/secrets.js"

      # 3. Root relative import
      assert.equal "src/helper.js",
        transformEntry
          scope: "/"
          specifier: "./helper.js"
          target: "/src/helper.js"

      # 4. Scoped bare import (un-nested target)
      assert.equal "node_modules/package-a/node_modules/shared-dependency/index.js",
        transformEntry
          scope: "/node_modules/package-a@1.0.0/"
          specifier: "shared-dependency"
          target: "/node_modules/shared-dependency@1.0.0/index.js"

      # 4b. Scoped bare import (hierarchical target)
      assert.equal "node_modules/package-a/node_modules/shared-dependency/index.js",
        transformEntry
          scope: "/node_modules/package-a@1.0.0/"
          specifier: "shared-dependency"
          target: "/node_modules/package-a@1.0.0/node_modules/shared-dependency@1.0.0/index.js"

      # 5. Scoped relative import within package
      assert.equal "node_modules/package-a/src/sub.js",
        transformEntry
          scope: "/node_modules/package-a@1.0.0/"
          specifier: "./sub.js"
          target: "/node_modules/package-a@1.0.0/src/sub.js"

      # 6. Scoped subpath alias import (#alias)
      assert.equal "node_modules/package-a/src/helpers/index.js",
        transformEntry
          scope: "/node_modules/package-a@1.0.0/"
          specifier: "#helpers"
          target: "/node_modules/package-a@1.0.0/src/helpers/index.js"

      # 7. Scoped relative import from within a package subdirectory
      assert.equal "node_modules/@scope/package-a/build/node/src/authorizer.js",
        transformEntry
          scope: "/node_modules/@scope/package-a@1.0.0/build/node/src/"
          specifier: "./authorizer.js"
          target: "/node_modules/@scope/package-a@1.0.0/build/node/src/authorizer.js"

      # 8. Nested package relative import within nested package subdirectory
      assert.equal "node_modules/pkg-a/node_modules/nested-pkg/build/node/src/handler.js",
        transformEntry
          scope: "/node_modules/pkg-a@1.0.0/node_modules/nested-pkg@2.0.0/build/node/src/"
          specifier: "./handler.js"
          target: "/node_modules/pkg-a@1.0.0/node_modules/nested-pkg@2.0.0/build/node/src/handler.js"

      # 9. Scoped namespace nested package import
      assert.equal "node_modules/@dashkite/kaiko/node_modules/@dashkite/joy/build/node/src/index.js",
        transformEntry
          scope: "/node_modules/@dashkite/kaiko@0.3.3/"
          specifier: "@dashkite/joy"
          target: "/node_modules/@dashkite/kaiko@0.3.3/node_modules/@dashkite/joy@0.7.0/build/node/src/index.js"

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

      nestedBuffer = await bundle "src/index.js", root: nestedDirectory, preset: "npm"
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
