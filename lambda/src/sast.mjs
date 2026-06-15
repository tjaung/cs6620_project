import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { createWriteStream, promises as fs } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import zlib from "node:zlib";

const s3 = new S3Client({});

const SAST_SERVICE_URL = trimTrailingSlash(process.env.SAST_SERVICE_URL ?? "");
const MAX_FILES_TO_SCAN = Number.parseInt(process.env.MAX_FILES_TO_SCAN ?? "80", 10);
const MAX_FILE_BYTES = Number.parseInt(process.env.MAX_FILE_BYTES ?? "524288", 10);
const SAST_EXTENSIONS = new Set([".cjs", ".js", ".jsx", ".mjs", ".ts", ".tsx"]);

export const runSastTest = async ({ s3Bucket, s3Key }) => {
  if (!SAST_SERVICE_URL) {
    return {
      success: false,
      passed: false,
      error: "Missing SAST_SERVICE_URL Lambda environment variable"
    };
  }

  const workDir = await fs.mkdtemp(path.join(tmpdir(), "repo-sast-"));
  const zipPath = path.join(workDir, "repo.zip");
  const extractDir = path.join(workDir, "repo");

  await fs.mkdir(extractDir, { recursive: true });
  await downloadS3Object(s3Bucket, s3Key, zipPath);
  await unzip(zipPath, extractDir);

  const files = await collectFiles(extractDir);
  const matchedSourceFiles = files.filter((file) => SAST_EXTENSIONS.has(path.extname(file.relativePath).toLowerCase()));
  const sourceFiles = matchedSourceFiles.slice(0, MAX_FILES_TO_SCAN);
  const scanResults = [];
  const skippedFiles = [];
  const failedFiles = [];

  for (const file of sourceFiles) {
    const stats = await fs.stat(file.absolutePath);

    if (stats.size > MAX_FILE_BYTES) {
      skippedFiles.push({
        path: file.relativePath,
        reason: `File is larger than MAX_FILE_BYTES (${MAX_FILE_BYTES})`,
        bytes: stats.size
      });
      continue;
    }

    try {
      const code = await fs.readFile(file.absolutePath, "utf8");
      const scanResult = await scanCodeWithSast(file.relativePath, code);
      scanResults.push(scanResult);
    } catch (error) {
      failedFiles.push({
        path: file.relativePath,
        error: error.message
      });
    }
  }

  const vulnerabilities = scanResults.flatMap((scanResult) => scanResult.vulnerabilities ?? []);
  const summary = summarizeVulnerabilities(vulnerabilities);

  return {
    success: failedFiles.length === 0,
    passed: summary.high === 0 && failedFiles.length === 0,
    serviceUrl: SAST_SERVICE_URL,
    filesDiscovered: files.length,
    sourceFilesMatched: matchedSourceFiles.length,
    filesScanned: scanResults.length,
    filesSkipped: skippedFiles.length,
    filesFailed: failedFiles.length,
    maxFilesToScan: MAX_FILES_TO_SCAN,
    maxFileBytes: MAX_FILE_BYTES,
    summary,
    skippedFiles,
    failedFiles,
    vulnerabilities
  };
};

const scanCodeWithSast = async (filename, code) => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15000);

  try {
    const response = await fetch(`${SAST_SERVICE_URL}/scan/code`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ filename, code }),
      signal: controller.signal
    });

    const body = await response.json();

    if (!response.ok || body.success === false) {
      throw new Error(body.message || body.error || `SAST request failed with ${response.status}`);
    }

    return {
      filename,
      summary: body.summary,
      vulnerabilities: body.vulnerabilities ?? []
    };
  } finally {
    clearTimeout(timeout);
  }
};

const summarizeVulnerabilities = (vulnerabilities) => ({
  totalVulnerabilities: vulnerabilities.length,
  high: vulnerabilities.filter((vulnerability) => vulnerability.severity === "HIGH").length,
  medium: vulnerabilities.filter((vulnerability) => vulnerability.severity === "MEDIUM").length,
  low: vulnerabilities.filter((vulnerability) => vulnerability.severity === "LOW").length
});

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
  return [".git", "node_modules", "dist", "build", "coverage", ".terraform"].includes(name);
};

function trimTrailingSlash(value) {
  return value.endsWith("/") ? value.slice(0, -1) : value;
}
