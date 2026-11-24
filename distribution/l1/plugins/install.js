const fs = require("fs");
const os = require("os");
const path = require("path");

function realPath(file) {
  try {
    return fs.realpathSync(file);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return path.join(realPath(path.dirname(file)), path.basename(file));
  }
}

function checkDirectory(directory) {
  const stat = fs.lstatSync(directory, { throwIfNoEntry: false });
  if (stat && !stat.isDirectory()) throw new Error(`路径不是普通目录：${directory}`);
  return Boolean(stat);
}

function install(target, check) {
  const manifest = require("./manifest.json");
  const bundle = path.join(__dirname, "bundle");
  const ids = checkDirectory(bundle)
    ? fs.readdirSync(bundle, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort()
    : [];
  const installed = new Set(ids);
  for (const plugin of manifest) {
    if (!installed.has(plugin.id)) console.log(`  WARN 插件缺源：${plugin.id}`);
  }
  if (ids.length === 0) return;

  const dsh = path.join(realPath(path.resolve(target)), ".dsh");
  const homeDsh = path.join(os.homedir(), ".dsh");
  const protectedPaths = [path.resolve(homeDsh), realPath(homeDsh)];
  if (protectedPaths.some((dir) => dsh === dir || dsh.startsWith(dir + path.sep))) {
    throw new Error("插件目标必须在 ~/.dsh 之外");
  }
  const plugins = path.join(dsh, "plugins");
  checkDirectory(dsh);
  checkDirectory(plugins);

  for (const id of ids) {
    const dest = path.join(plugins, id);
    if (checkDirectory(dest)) {
      console.log(`  skip      插件 ${id}（已存在）`);
    } else if (check) {
      console.log(`  missing   插件 ${id}（安装时会复制）`);
    } else {
      fs.mkdirSync(plugins, { recursive: true });
      const staging = fs.mkdtempSync(path.join(plugins, ".install-"));
      try {
        const pending = path.join(staging, id);
        fs.cpSync(path.join(bundle, id), pending, {
          recursive: true,
          filter(source) {
            const stat = fs.lstatSync(source);
            if (!stat.isDirectory() && !stat.isFile()) throw new Error(`插件只接收普通文件和目录：${source}`);
            return true;
          },
        });
        if (checkDirectory(dest)) {
          console.log(`  skip      插件 ${id}（已存在）`);
        } else {
          fs.renameSync(pending, dest);
          console.log(`  PASS 插件已复制：${id}`);
        }
      } finally {
        fs.rmSync(staging, { recursive: true, force: true });
      }
    }
  }
}

try {
  install(process.argv[2], process.argv[3] === "1");
} catch (error) {
  console.error(`  FAIL 插件安装：${error.message}`);
  process.exitCode = 1;
}
