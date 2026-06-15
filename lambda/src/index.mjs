import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { runPentest } from "./pentest.mjs";
import { runSastTest } from "./sast.mjs";

const s3 = new S3Client({});

export const handler = async (event) => {
  const payload = typeof event === "string" ? JSON.parse(event) : event;
  const {
    s3Bucket,
    s3Key,
    repo = "unknown",
    sha = "unknown",
    runId = "unknown",
    pentestTargetUrl = ""
  } = payload ?? {};
  const scanners = parseScanners(payload?.scanners);

  if (!s3Bucket || !s3Key) {
    return response(400, {
      success: false,
      error: "Missing s3Bucket or s3Key in Lambda payload"
    });
  }

  const result = {
    success: true,
    passed: true,
    repo,
    sha,
    runId,
    scanners,
    source: {
      bucket: s3Bucket,
      key: s3Key
    }
  };

  if (scanners.includes("sast")) {
    result.sast = await runSastTest({ s3Bucket, s3Key });
    result.success = result.success && result.sast.success;
    result.passed = result.passed && result.sast.passed;
  }

  if (scanners.includes("pentest")) {
    result.pentest = await runPentest({ targetUrl: pentestTargetUrl });
    result.success = result.success && result.pentest.success;
    result.passed = result.passed && result.pentest.passed;
  }

  await writeResultArtifact(s3Bucket, s3Key, result);

  return response(200, result);
};

const parseScanners = (value) => {
  if (Array.isArray(value)) {
    return normalizeScanners(value);
  }

  if (typeof value === "string" && value.trim()) {
    return normalizeScanners(value.split(","));
  }

  return ["sast"];
};

const normalizeScanners = (values) => {
  const scanners = values
    .map((value) => String(value).trim().toLowerCase())
    .filter((value) => ["sast", "pentest"].includes(value));

  return [...new Set(scanners.length > 0 ? scanners : ["sast"])];
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
