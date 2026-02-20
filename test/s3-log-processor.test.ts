import type { Context, EventBridgeEvent, Handler } from 'aws-lambda';
import { gzipSync } from 'node:zlib';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const s3Mocks = vi.hoisted(() => {
  const send = vi.fn();
  const S3Client = vi.fn().mockImplementation(function S3ClientMock() {
    return {
      send
    };
  });
  const GetObjectCommand = vi.fn().mockImplementation(function GetObjectCommandMock(input: unknown) {
    return {
      input
    };
  });

  return {
    send,
    S3Client,
    GetObjectCommand
  };
});

const sitelineMocks = vi.hoisted(() => {
  const track = vi.fn<(data: unknown) => void>();
  const Siteline = vi.fn().mockImplementation(function SitelineMock() {
    return {
      track
    };
  });

  return {
    track,
    Siteline
  };
});

vi.mock('@aws-sdk/client-s3', () => {
  return {
    S3Client: s3Mocks.S3Client,
    GetObjectCommand: s3Mocks.GetObjectCommand
  };
});

vi.mock('@siteline/core', () => {
  return {
    Siteline: sitelineMocks.Siteline
  };
});

interface S3ObjectCreatedDetail {
  bucket: {
    name: string;
  };
  object: {
    key: string;
  };
}

type S3LogEvent = EventBridgeEvent<string, S3ObjectCreatedDetail>;
type S3LogHandler = Handler<S3LogEvent, void>;

type FastlyTestLogRecord = Readonly<Record<string, string | number | null>>;

const createEvent = (
  bucketName = 'fastly-log-bucket',
  objectKey = 'logs%2F2026-02-18-00.log.gz'
): S3LogEvent => {
  return {
    version: '0',
    id: 'event-id',
    'detail-type': 'Object Created',
    source: 'aws.s3',
    account: '123456789012',
    time: '2026-02-18T12:00:00Z',
    region: 'us-east-1',
    resources: [],
    detail: {
      bucket: {
        name: bucketName
      },
      object: {
        key: objectKey
      }
    }
  };
};

const createContext = (): Context => {
  return {
    awsRequestId: 'aws-request-id',
    callbackWaitsForEmptyEventLoop: false,
    functionName: 's3-log-processor',
    functionVersion: '$LATEST',
    invokedFunctionArn: 'arn:aws:lambda:us-east-1:123456789012:function:s3-log-processor',
    memoryLimitInMB: '256',
    logGroupName: '/aws/lambda/s3-log-processor',
    logStreamName: '2026/02/18/[$LATEST]1234567890',
    getRemainingTimeInMillis: () => 10_000,
    done: () => undefined,
    fail: () => undefined,
    succeed: () => undefined
  };
};

const buildLog = (rows: readonly FastlyTestLogRecord[]): string => {
  return rows.map((row) => JSON.stringify(row)).join('\n');
};

const setS3Body = (rawLog: string, options?: { gzip?: boolean }): void => {
  const shouldGzip = options?.gzip ?? true;
  const payload = shouldGzip ? gzipSync(Buffer.from(rawLog, 'utf8')) : Buffer.from(rawLog, 'utf8');

  s3Mocks.send.mockResolvedValue({
    Body: {
      transformToByteArray: vi.fn().mockResolvedValue(payload)
    }
  });
};

const loadHandler = async (): Promise<S3LogHandler> => {
  const module = await import('../src/handlers/s3-log-processor.js');
  return module.handler as S3LogHandler;
};

const invokeHandler = async (handler: S3LogHandler, event: S3LogEvent): Promise<void> => {
  await handler(event, createContext(), () => undefined);
};

describe('s3-log-processor handler', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.restoreAllMocks();

    process.env.APP_NAME = 'siteline-fastly-s3-processor';
    process.env.SITELINE_WEBSITE_KEY = 'siteline_secret_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    process.env.SITELINE_ENDPOINT = 'https://siteline.ai/v1/intake/pageview';
    process.env.SITELINE_DEBUG = 'false';

    s3Mocks.send.mockReset();
    s3Mocks.S3Client.mockReset();
    s3Mocks.GetObjectCommand.mockReset();
    s3Mocks.S3Client.mockImplementation(function S3ClientMock() {
      return {
        send: s3Mocks.send
      };
    });
    s3Mocks.GetObjectCommand.mockImplementation(function GetObjectCommandMock(input: unknown) {
      return {
        input
      };
    });

    sitelineMocks.track.mockReset();
    sitelineMocks.Siteline.mockReset();
    sitelineMocks.Siteline.mockImplementation(function SitelineMock() {
      return {
        track: sitelineMocks.track
      };
    });
  });

  it('tracks pageviews from valid gzip Fastly JSON logs', async () => {
    setS3Body(
      buildLog([
        {
          host: 'www.example.com',
          url: '/health?a=1&b=2',
          request_method: 'GET',
          response_status: 204,
          time_elapsed_usec: 123000,
          request_user_agent: 'Mozilla/5.0 (Test)',
          request_referer: 'https://example.com/',
          client_ip: '203.0.113.10'
        },
        {
          host: 'www.example.com',
          url: '/api/ingest',
          request_method: 'POST',
          response_status: 201,
          time_elapsed_usec: 10000,
          request_user_agent: null,
          request_referer: null,
          client_ip: '203.0.113.11'
        },
        {
          host: 'www.example.com',
          url: '/not-found?debug=true',
          request_method: 'GET',
          response_status: 404,
          time_elapsed_usec: 1500000,
          request_user_agent: 'curl/8.7.1',
          request_referer: 'https://ref.example/path',
          client_ip: '203.0.113.12'
        }
      ])
    );

    const handler = await loadHandler();
    await invokeHandler(handler, createEvent());

    expect(s3Mocks.GetObjectCommand).toHaveBeenCalledWith({
      Bucket: 'fastly-log-bucket',
      Key: 'logs/2026-02-18-00.log.gz'
    });

    expect(sitelineMocks.track).toHaveBeenCalledTimes(3);
    expect(sitelineMocks.track).toHaveBeenNthCalledWith(1, {
      url: 'https://www.example.com/health?a=1&b=2',
      method: 'GET',
      status: 204,
      duration: 123,
      userAgent: 'Mozilla/5.0 (Test)',
      ref: 'https://example.com/',
      ip: '203.0.113.10'
    });
    expect(sitelineMocks.track).toHaveBeenNthCalledWith(2, {
      url: 'https://www.example.com/api/ingest',
      method: 'POST',
      status: 201,
      duration: 10,
      userAgent: null,
      ref: null,
      ip: '203.0.113.11'
    });
    expect(sitelineMocks.track).toHaveBeenNthCalledWith(3, {
      url: 'https://www.example.com/not-found?debug=true',
      method: 'GET',
      status: 404,
      duration: 1500,
      userAgent: 'curl/8.7.1',
      ref: 'https://ref.example/path',
      ip: '203.0.113.12'
    });
  });

  it('skips rows with invalid status or missing url without throwing', async () => {
    setS3Body(
      buildLog([
        {
          host: 'www.example.com',
          url: '/missing-status',
          request_method: 'GET',
          response_status: '-',
          time_elapsed_usec: 300000,
          request_user_agent: 'Mozilla/5.0',
          request_referer: null,
          client_ip: '203.0.113.10'
        },
        {
          host: 'www.example.com',
          request_method: 'GET',
          response_status: 200,
          time_elapsed_usec: 300000,
          request_user_agent: 'Mozilla/5.0',
          request_referer: null,
          client_ip: '203.0.113.11'
        },
        {
          host: 'www.example.com',
          url: '/valid?ok=1',
          request_method: 'GET',
          response_status: 200,
          time_elapsed_usec: 400000,
          request_user_agent: 'Mozilla/5.0',
          request_referer: null,
          client_ip: '203.0.113.13'
        }
      ])
    );

    const handler = await loadHandler();

    await expect(invokeHandler(handler, createEvent())).resolves.toBeUndefined();
    expect(sitelineMocks.track).toHaveBeenCalledTimes(1);
    expect(sitelineMocks.track).toHaveBeenCalledWith({
      url: 'https://www.example.com/valid?ok=1',
      method: 'GET',
      status: 200,
      duration: 400,
      userAgent: 'Mozilla/5.0',
      ref: null,
      ip: '203.0.113.13'
    });
  });

  it('is fail-open on malformed rows and continues processing valid rows', async () => {
    const rawLog = [
      JSON.stringify({
        host: 'www.example.com',
        url: '/first?a=1',
        request_method: 'GET',
        response_status: 200,
        time_elapsed_usec: 200000,
        request_user_agent: 'Mozilla/5.0',
        request_referer: null,
        client_ip: '203.0.113.10'
      }),
      'malformed-row-without-json',
      JSON.stringify({
        host: 'www.example.com',
        url: '/third',
        request_method: 'GET',
        response_status: 200,
        time_elapsed_usec: 300000,
        request_user_agent: 'curl/8.7.1',
        request_referer: null,
        client_ip: '203.0.113.12'
      })
    ].join('\n');

    setS3Body(rawLog);

    const handler = await loadHandler();

    await expect(invokeHandler(handler, createEvent())).resolves.toBeUndefined();
    expect(sitelineMocks.track).toHaveBeenCalledTimes(2);
    expect(sitelineMocks.track).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({
        url: 'https://www.example.com/first?a=1',
        status: 200,
        duration: 200
      })
    );
    expect(sitelineMocks.track).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        url: 'https://www.example.com/third',
        status: 200,
        duration: 300
      })
    );
  });

  it('supports uncompressed Fastly log objects', async () => {
    setS3Body(
      buildLog([
        {
          url: 'https://example.com/plain',
          request_method: 'GET',
          response_status: 200,
          duration_ms: 42,
          request_user_agent: 'UnitTest/1.0',
          request_referer: null,
          client_ip: '203.0.113.22'
        }
      ]),
      { gzip: false }
    );

    const handler = await loadHandler();

    await expect(invokeHandler(handler, createEvent())).resolves.toBeUndefined();
    expect(sitelineMocks.track).toHaveBeenCalledTimes(1);
    expect(sitelineMocks.track).toHaveBeenCalledWith(
      expect.objectContaining({
        url: 'https://example.com/plain',
        status: 200,
        duration: 42
      })
    );
  });

  it('skips processing when website key is missing', async () => {
    process.env.SITELINE_WEBSITE_KEY = '';

    const handler = await loadHandler();
    await expect(invokeHandler(handler, createEvent())).resolves.toBeUndefined();

    expect(sitelineMocks.Siteline).not.toHaveBeenCalled();
    expect(sitelineMocks.track).not.toHaveBeenCalled();
    expect(s3Mocks.send).not.toHaveBeenCalled();
  });

  it('throws when S3 download fails', async () => {
    s3Mocks.send.mockRejectedValue(new Error('s3 unavailable'));

    const handler = await loadHandler();

    await expect(invokeHandler(handler, createEvent())).rejects.toThrow('s3 unavailable');
    expect(sitelineMocks.track).not.toHaveBeenCalled();
  });
});
