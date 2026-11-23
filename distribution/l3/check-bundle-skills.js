const fs = require('node:fs');
const path = require('node:path');

function fail(message) {
  console.log(`FAIL ${message}`);
  process.exitCode = 1;
}

function addEntry(tree, relative, absolute, entry) {
  if (tree.has(relative)) {
    fail(`${absolute} 与 ${tree.get(relative).absolute} 平铺后路径重复：${relative}`);
    return;
  }
  if (!entry.isFile() && !entry.isDirectory()) {
    fail(`${absolute} 不是普通文件或目录`);
    return;
  }

  const directory = entry.isDirectory();
  tree.set(relative, { absolute, directory });
  if (directory) readTree(absolute, tree, `${relative}/`);
}

function readTree(root, tree, prefix = '') {
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    addEntry(tree, prefix + entry.name, path.join(root, entry.name), entry);
  }
}

function checkBundleSkills(platformDir) {
  const manifest = JSON.parse(fs.readFileSync(path.join(platformDir, 'manifest.json'), 'utf8'));
  if (manifest.tier !== 'full') return;

  const source = new Map();
  const layeredRoot = path.join(platformDir, 'skills');
  // 只映射 <层>/<skill>，根目录的 REFERENCES.md 属于平台元数据。
  for (const layer of fs.readdirSync(layeredRoot, { withFileTypes: true })) {
    if (!layer.isDirectory()) continue;
    const layerDir = path.join(layeredRoot, layer.name);
    for (const skill of fs.readdirSync(layerDir, { withFileTypes: true })) {
      const skillDir = path.join(layerDir, skill.name);
      if (!skill.isDirectory()) {
        fail(`${skillDir} 不是 skill 目录`);
        continue;
      }
      addEntry(source, skill.name, skillDir, skill);
      if (source.get(`${skill.name}/SKILL.md`)?.directory !== false) {
        fail(`${skillDir}/SKILL.md 缺失或不是普通文件`);
      }
    }
  }

  const bundled = new Map();
  const bundleRoot = path.join(platformDir, 'bundle', 'skills');
  if (!fs.lstatSync(bundleRoot).isDirectory()) {
    fail(`${bundleRoot} 不是普通目录`);
    return;
  }
  readTree(bundleRoot, bundled);

  let fileCount = 0;
  for (const [relative, entry] of source) {
    const mirror = bundled.get(relative);
    if (!mirror) {
      fail(`bundle/skills/${relative} 缺失`);
    } else if (entry.directory !== mirror.directory) {
      fail(`bundle/skills/${relative} 文件类型不同`);
    } else if (!entry.directory) {
      fileCount++;
      if (!fs.readFileSync(entry.absolute).equals(fs.readFileSync(mirror.absolute))) {
        fail(`bundle/skills/${relative} 内容不同`);
      }
    }
  }
  for (const relative of bundled.keys()) {
    if (!source.has(relative)) fail(`bundle/skills/${relative} 多余`);
  }

  if (!process.exitCode) console.log(`PASS bundle skills 与分层 skills 一致（${fileCount} 个文件）`);
}

try {
  checkBundleSkills(process.argv[2]);
} catch (error) {
  fail(`bundle skills 镜像校验失败：${error.message}`);
}
