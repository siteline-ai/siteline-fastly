import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { Siteline, type PageviewData, type SitelineConfig } from '@siteline/core';
import type { EventBridgeEvent, Handler } from 'aws-lambda';
import { gunzipSync } from 'node:zlib';

import {
  DEFAULT_INTEGRATION_TYPE,
  DEFAULT_SDK_NAME,
  DEFAULT_SDK_VERSION
} from '../config/constants';
import { appConfig } from '../config/env';

interface S3ObjectCreatedDetail {
  bucket?: {
    name?: string;
  };
  object?: {
    key?: string;
  };
}

type S3LogEvent = EventBridgeEvent<string, S3ObjectCreatedDetail>;
type FastlyLogRecord = Readonly<Record<string, unknown>>;

const COMMENT_PREFIX = '#';

const s3Region = process.env.AWS_REGION ?? process.env.S3_BUCKET_REGION;
const s3Client = s3Region ? new S3Client({ region: s3Region }) : new S3Client();

const logTrackingError = (message: string, error: unknown): void => {
  const errorMessage = error instanceof Error ? error.message : 'Unknown error';
  console.error(
    JSON.stringify({
      service: appConfig.appName,
      message,
      errorMessage
    })
  );
};

const createSitelineClient = (): Siteline | undefined => {
  const websiteKey = appConfig.siteline.websiteKey;
  if (!websiteKey) {
    return undefined;
  }

  const config: SitelineConfig = {
    websiteKey,
    debug: appConfig.siteline.debug
  };

  if (appConfig.siteline.endpoint) {
    config.endpoint = appConfig.siteline.endpoint;
  }

  try {
    return new Siteline({
      ...config,
      sdk: DEFAULT_SDK_NAME,
      sdkVersion: DEFAULT_SDK_VERSION,
      integrationType: DEFAULT_INTEGRATION_TYPE
    });
  } catch (error: unknown) {
    logTrackingError('Siteline initialization failed; tracking disabled.', error);
    return undefined;
  }
};

const siteline = createSitelineClient();

const decodeS3ObjectKey = (value: string): string => {
  return decodeURIComponent(value.replace(/\+/g, ' '));
};

const asString = (value: unknown): string | undefined => {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed || trimmed === '-') {
      return undefined;
    }

    return trimmed;
  }

  if (typeof value === 'number' && Number.isFinite(value)) {
    return String(value);
  }

  return undefined;
};

const asNullableString = (value: unknown): string | null => {
  return asString(value) ?? null;
};

const parseNonNegativeNumber = (value: unknown): number | undefined => {
  if (typeof value === 'number') {
    return Number.isFinite(value) && value >= 0 ? value : undefined;
  }

  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed || trimmed === '-') {
      return undefined;
    }

    const parsed = Number.parseFloat(trimmed);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined;
  }

  return undefined;
};

const parseStatus = (value: unknown): number | undefined => {
  const parsed = parseNonNegativeNumber(value);
  if (parsed === undefined) {
    return undefined;
  }

  const status = Math.trunc(parsed);
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    return undefined;
  }

  return status;
};

const parseDurationMs = (record: FastlyLogRecord): number => {
  const durationUsec =
    parseNonNegativeNumber(record.time_elapsed_usec) ??
    parseNonNegativeNumber(record.time_elapsed_us) ??
    parseNonNegativeNumber(record.duration_usec);

  if (durationUsec !== undefined) {
    return Math.round(durationUsec / 1000);
  }

  const durationMs =
    parseNonNegativeNumber(record.time_elapsed_ms) ??
    parseNonNegativeNumber(record.duration_ms) ??
    parseNonNegativeNumber(record.time_taken_ms);

  if (durationMs !== undefined) {
    return Math.round(durationMs);
  }

  return 0;
};

const parseJsonLogLine = (line: string): FastlyLogRecord => {
  const parsed: unknown = JSON.parse(line);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Fastly log row is not a JSON object.');
  }

  return parsed as FastlyLogRecord;
};

const buildAbsoluteUrl = (rawUrl: string, host?: string): string => {
  if (/^https?:\/\//i.test(rawUrl)) {
    return rawUrl;
  }

  if (!host) {
    return rawUrl;
  }

  if (rawUrl.startsWith('/')) {
    return `https://${host}${rawUrl}`;
  }

  return `https://${host}/${rawUrl}`;
};

const toPageviewData = (line: string): PageviewData | undefined => {
  const record = parseJsonLogLine(line);

  const status = parseStatus(record.response_status ?? record.status);
  if (status === undefined) {
    return undefined;
  }

  const rawUrl = asString(record.url) ?? asString(record.request_url) ?? asString(record.path);
  if (!rawUrl) {
    return undefined;
  }

  const host = asString(record.host) ?? asString(record.request_host) ?? asString(record.req_header_host);

  return {
    url: buildAbsoluteUrl(rawUrl, host),
    method: asString(record.request_method) ?? asString(record.method) ?? 'UNKNOWN',
    status,
    duration: parseDurationMs(record),
    userAgent:
      asNullableString(record.request_user_agent) ??
      asNullableString(record.req_header_user_agent) ??
      asNullableString(record.user_agent),
    ref:
      asNullableString(record.request_referer) ??
      asNullableString(record.req_header_referer) ??
      asNullableString(record.referer),
    ip: asNullableString(record.client_ip) ?? asNullableString(record.ip)
  };
};

const getObjectBodyBuffer = async (bucketName: string, objectKey: string): Promise<Buffer> => {
  const response = await s3Client.send(
    new GetObjectCommand({
      Bucket: bucketName,
      Key: objectKey
    })
  );

  const body = response.Body;
  if (!body || typeof body !== 'object' || !('transformToByteArray' in body)) {
    throw new Error('S3 GetObject returned an empty or unsupported body.');
  }

  const transform = body.transformToByteArray;
  if (typeof transform !== 'function') {
    throw new Error('S3 GetObject body does not support transformToByteArray().');
  }

  const payload = await transform.call(body);
  return Buffer.from(payload);
};

const getRawLogFile = async (bucketName: string, objectKey: string): Promise<string> => {
  let objectContent: Buffer;
  try {
    objectContent = await getObjectBodyBuffer(bucketName, objectKey);
  } catch (error: unknown) {
    logTrackingError('Failed to download Fastly log object from S3.', error);
    throw error;
  }

  try {
    return gunzipSync(objectContent).toString('utf8');
  } catch {
    return objectContent.toString('utf8');
  }
};

const getBucketAndKey = (event: S3LogEvent): { bucketName: string; objectKey: string } => {
  const bucketName = event.detail?.bucket?.name;
  const rawObjectKey = event.detail?.object?.key;

  if (!bucketName || !rawObjectKey) {
    const error = new Error('EventBridge S3 event is missing bucket.name or object.key.');
    logTrackingError('Invalid S3 event payload.', error);
    throw error;
  }

  let objectKey: string;
  try {
    objectKey = decodeS3ObjectKey(rawObjectKey);
  } catch (error: unknown) {
    logTrackingError('Failed to decode S3 object key from event payload.', error);
    throw error;
  }

  return {
    bucketName,
    objectKey
  };
};

export const handler: Handler<S3LogEvent, void> = async (event) => {
  if (!siteline) {
    return;
  }

  const { bucketName, objectKey } = getBucketAndKey(event);
  const rawLog = await getRawLogFile(bucketName, objectKey);

  const trackPromises: Promise<void>[] = [];

  for (const line of rawLog.split(/\r?\n/)) {
    const trimmedLine = line.trim();
    if (!trimmedLine || trimmedLine.startsWith(COMMENT_PREFIX)) {
      continue;
    }

    try {
      const pageview = toPageviewData(trimmedLine);
      if (!pageview) {
        continue;
      }

      trackPromises.push(siteline.track(pageview));
    } catch (error: unknown) {
      logTrackingError('Failed to parse Fastly log row; row skipped.', error);
    }
  }

  await Promise.all(trackPromises);
};
