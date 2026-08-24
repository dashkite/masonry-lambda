import esbuild from "esbuild";
import Path from "node:path";
import fs from "node:fs/promises";
import JSZip from "jszip";
import pkg from "@dashkite/masonry-lambda";
const { bundle } = pkg;


async function main() {
  const shellEntry = "/Users/dan/repos/dashkite/central-park/cerulean/build/node/src/shell/index.js";
  const buffer = await bundle(shellEntry);
  const zip = await JSZip.loadAsync(buffer);
  await fs.writeFile("/Users/dan/repos/dashkite/central-park/.gemini/antigravity-cli/brain/3620432e-dd21-4ebb-8705-22f2d72b40e8/scratch/bundle.zip", buffer);
  console.log("Bundle ZIP written successfully.");


  // Also print all files that are inside the zip
  const files = Object.keys(zip.files);
  console.log(`Total files in ZIP: ${files.length}`);
  
  // Search for JSON.parse in the files inside the zip
  for (const filename of files) {
    if (filename.endsWith(".js")) {
      const content = await zip.files[filename].async("text");
      if (content.includes("JSON.parse")) {
        console.log(`JSON.parse found in: ${filename}`);
        // Print lines containing JSON.parse
        const lines = content.split("\n");
        lines.forEach((line, idx) => {
          if (line.includes("JSON.parse")) {
            console.log(`  L${idx + 1}: ${line.trim()}`);
          }
        });
      }
    }
  }
}

main().catch(console.error);
