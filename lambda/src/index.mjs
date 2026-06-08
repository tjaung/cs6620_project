import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { createWriteStream, promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import zlib from "node:zlib";

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
  const zipBuffer = await fs.readFile(zipPath);
  const entries = readZipEntries(zipBuffer);

  for (const entry of entries) {
    if (entry.isDirectory) {
      continue;
    }

    const destinationPath = safeJoin(destinationDir, entry.name);
    await fs.mkdir(path.dirname(destinationPath), { recursive: true });
    await fs.writeFile(destinationPath, entry.content);
  }
};

const readZipEntries = (zipBuffer) => {
  const entries = [];
  const endOfCentralDirectoryOffset = findEndOfCentralDirectory(zipBuffer);

  if (endOfCentralDirectoryOffset === -1) {
    throw new Error("Could not find ZIP end of central directory record");
  }

  const centralDirectorySize = zipBuffer.readUInt32LE(endOfCentralDirectoryOffset + 12);
  const centralDirectoryOffset = zipBuffer.readUInt32LE(endOfCentralDirectoryOffset + 16);
  const centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize;
  let cursor = centralDirectoryOffset;

  while (cursor < centralDirectoryEnd) {
    const centralDirectorySignature = zipBuffer.readUInt32LE(cursor);

    if (centralDirectorySignature !== 0x02014b50) {
      throw new Error("Invalid ZIP central directory entry");
    }

    const compressionMethod = zipBuffer.readUInt16LE(cursor + 10);
    const compressedSize = zipBuffer.readUInt32LE(cursor + 20);
    const uncompressedSize = zipBuffer.readUInt32LE(cursor + 24);
    const fileNameLength = zipBuffer.readUInt16LE(cursor + 28);
    const extraFieldLength = zipBuffer.readUInt16LE(cursor + 30);
    const fileCommentLength = zipBuffer.readUInt16LE(cursor + 32);
    const localHeaderOffset = zipBuffer.readUInt32LE(cursor + 42);
    const fileNameStart = cursor + 46;
    const fileNameEnd = fileNameStart + fileNameLength;
    const name = zipBuffer.toString("utf8", fileNameStart, fileNameEnd);

    entries.push(readZipEntryContent(zipBuffer, {
      name,
      compressionMethod,
      compressedSize,
      uncompressedSize,
      localHeaderOffset
    }));

    cursor = fileNameEnd + extraFieldLength + fileCommentLength;
  }

  return entries;
};

const findEndOfCentralDirectory = (zipBuffer) => {
  const signature = 0x06054b50;
  const minimumRecordSize = 22;

  for (let offset = zipBuffer.length - minimumRecordSize; offset >= 0; offset -= 1) {
    if (zipBuffer.readUInt32LE(offset) === signature) {
      return offset;
    }
  }

  return -1;
};

const readZipEntryContent = (zipBuffer, entry) => {
  const localHeaderSignature = zipBuffer.readUInt32LE(entry.localHeaderOffset);

  if (localHeaderSignature !== 0x04034b50) {
    throw new Error(`Invalid ZIP local file header for ${entry.name}`);
  }

  const localFileNameLength = zipBuffer.readUInt16LE(entry.localHeaderOffset + 26);
  const localExtraFieldLength = zipBuffer.readUInt16LE(entry.localHeaderOffset + 28);
  const compressedDataStart = entry.localHeaderOffset + 30 + localFileNameLength + localExtraFieldLength;
  const compressedDataEnd = compressedDataStart + entry.compressedSize;
  const compressedContent = zipBuffer.subarray(compressedDataStart, compressedDataEnd);

  let content;

  if (entry.compressionMethod === 0) {
    content = compressedContent;
  } else if (entry.compressionMethod === 8) {
    content = zlib.inflateRawSync(compressedContent);
  } else {
    throw new Error(`Unsupported ZIP compression method ${entry.compressionMethod} for ${entry.name}`);
  }

  if (content.length !== entry.uncompressedSize) {
    throw new Error(`ZIP entry size mismatch for ${entry.name}`);
  }

  return {
    name: entry.name,
    isDirectory: entry.name.endsWith("/"),
    content
  };
};

const safeJoin = (rootDir, relativePath) => {
  const destinationPath = path.resolve(rootDir, relativePath);
  const resolvedRoot = path.resolve(rootDir);

  if (!destinationPath.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error(`Unsafe ZIP path: ${relativePath}`);
  }

  return destinationPath;
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
