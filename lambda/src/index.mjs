import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { createWriteStream, promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const s3 = new S3Client({});

const MAX_FILES_TO_REPORT = Number.parseInt(process.env.MAX_FILES_TO_REPORT ?? "40", 10);
const MAX_BYTES_PER_FILE = Number.parseInt(process.env.MAX_BYTES_PER_FILE ?? "2000", 10);
const TEXT_EXTENSIONS = new Set([
  ".c",
  ".cjs",
  ".cpp",
  ".css",
  ".go",
  ".h",
  ".html",
  ".java",
  ".js",
  ".json",
  ".jsx",
  ".md",
  ".mjs",
  ".py",
  ".rb",
  ".sh",
  ".tf",
  ".ts",
  ".tsx",
  ".txt",
  ".yaml",
  ".yml"
]);

export const handler = async (event) => {
  const payload = typeof event === "string" ? JSON.parse(event) : event;
  const { s3Bucket, s3Key, repo = "unknown", sha = "unknown", runId = "unknown" } = payload ?? {};

  if (!s3Bucket || !s3Key) {
    return response(400, {
      success: false,
      error: "Missing s3Bucket or s3Key in Lambda payload"
    });
  }

  const workDir = await fs.mkdtemp(path.join(tmpdir(), "repo-scan-"));
  const zipPath = path.join(workDir, "repo.zip");
  const extractDir = path.join(workDir, "repo");

  await fs.mkdir(extractDir, { recursive: true });
  await downloadS3Object(s3Bucket, s3Key, zipPath);
  await unzip(zipPath, extractDir);

  const files = await collectFiles(extractDir);
  const textFiles = files.filter((file) => TEXT_EXTENSIONS.has(path.extname(file.relativePath).toLowerCase()));
  const previews = [];

  for (const file of textFiles.slice(0, MAX_FILES_TO_REPORT)) {
    const content = await fs.readFile(file.absolutePath, "utf8");
    previews.push({
      path: file.relativePath,
      bytes: Buffer.byteLength(content),
      preview: content.slice(0, MAX_BYTES_PER_FILE)
    });
  }

  const result = {
    success: true,
    repo,
    sha,
    runId,
    source: {
      bucket: s3Bucket,
      key: s3Key
    },
    summary: {
      totalFiles: files.length,
      textFiles: textFiles.length,
      reportedFiles: previews.length,
      maxFilesToReport: MAX_FILES_TO_REPORT,
      maxBytesPerFile: MAX_BYTES_PER_FILE
    },
    files: previews
  };

  await writeResultArtifact(s3Bucket, s3Key, result);

  return response(200, result);
};

const downloadS3Object = async (bucket, key, destinationPath) => {
  const result = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  await pipeline(result.Body, createWriteStream(destinationPath));
};

const unzip = async (zipPath, destinationDir) => {
  await execFileAsync("unzip", ["-q", zipPath, "-d", destinationDir]);
};

const collectFiles = async (rootDir) => {
  const files = [];

  const visit = async (currentDir) => {
    const entries = await fs.readdir(currentDir, { withFileTypes: true });

    for (const entry of entries) {
      const absolutePath = path.join(currentDir, entry.name);
      const relativePath = path.relative(rootDir, absolutePath);

      if (entry.isDirectory()) {
        if (shouldSkipDirectory(entry.name)) {
          continue;
        }
        await visit(absolutePath);
      } else if (entry.isFile()) {
        files.push({ absolutePath, relativePath });
      }
    }
  };

  await visit(rootDir);
  return files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
};

const shouldSkipDirectory = (name) => {
  return [".git", "node_modules", "dist", "build", "coverage"].includes(name);
};

const writeResultArtifact = async (bucket, sourceKey, result) => {
  const resultKey = sourceKey.replace(/repo\.zip$/, "result.json");

  await s3.send(new PutObjectCommand({
    Bucket: bucket,
    Key: resultKey,
    Body: JSON.stringify(result, null, 2),
    ContentType: "application/json"
  }));
};

const response = (statusCode, body) => ({
  statusCode,
  body: JSON.stringify(body, null, 2)
});
