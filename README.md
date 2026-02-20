# Siteline Fastly CDN S3 Log Processor

This project tracks Fastly traffic with Siteline.
It processes Fastly logs written to S3.
It forwards pageview events to the Siteline API.

## Architecture

```text
Existing Fastly service
  -> S3 logging endpoint
  -> S3 bucket (this project creates/configures it)
  -> EventBridge (Object Created)
  -> Lambda log processor (this project)
  -> Siteline API
```

## Prerequisites

- Node.js 18+ and npm
- AWS CLI v2
- `jq`
- `zip`
- `curl`
- Fastly API token with service write access
- IAM permissions for `s3`, `lambda`, `iam`, and `events` management

## AWS CLI Login

Use one of the following methods.

### Option 1: Access keys

```bash
aws configure
aws sts get-caller-identity
```

### Option 2: AWS SSO

```bash
aws configure sso
aws sso login --profile <your-profile>
aws sts get-caller-identity --profile <your-profile>
```

If you use SSO, set `AWS_PROFILE` in `.env`.

## Configuration

```bash
cp .env.example .env
```

Set at least:

- `SITELINE_WEBSITE_KEY`
- `LOG_BUCKET_NAME`
- `AWS_REGION`
- `FASTLY_API_TOKEN`
- `FASTLY_SERVICE_ID`
- `FASTLY_S3_ACCESS_KEY`
- `FASTLY_S3_SECRET_KEY`

## Setup Scripts

The scripts are idempotent.
They reuse existing resources when safe.
They stop on errors.

- `scripts/setup-s3.sh`
Creates/configures the S3 log bucket.
Enables S3 -> EventBridge notifications.

- `scripts/setup-lambda.sh`
Creates/updates IAM role and Lambda.
Deploys the packaged function.

- `scripts/setup-eventbridge.sh`
Creates the EventBridge rule.
Adds Lambda invoke permission.
Links S3 object-created events to Lambda.

- `scripts/setup-fastly.sh`
Creates or updates a Fastly S3 logging endpoint on the service.
Uses the configured JSON log format expected by the Lambda parser.
Activates the updated service version unless `FASTLY_SKIP_ACTIVATE=true`.

- `scripts/setup-all.sh`
Runs all setup scripts in order.

Run via npm:

```bash
npm run setup:s3
npm run setup:lambda
npm run setup:eventbridge
npm run setup:fastly
npm run setup:all
```

## Deployment Flow

1. Install dependencies.

```bash
npm install
```

2. Build and package Lambda.

```bash
npm run package
```

3. Provision AWS resources + Fastly logging endpoint.

```bash
npm run setup:all
```

For CI, disable prompts:

```bash
export AUTO_APPROVE=true
```

## Validation

Run local quality checks:

```bash
npm run ci
```

## Runtime Mapping

The processor expects newline-delimited JSON log records and maps:

- `url` from `url` (+ `host` when path-only)
- `method` from `request_method`
- `status` from `response_status`
- `duration` from `time_elapsed_usec` (converted to ms)
- `userAgent` from `request_user_agent`
- `ref` from `request_referer`
- `ip` from `client_ip`

Invalid rows are skipped.
Rows with invalid status or missing URI are ignored.

## Debugging Tips

Check caller identity:

```bash
aws sts get-caller-identity --region "${AWS_REGION}"
```

Tail Lambda logs:

```bash
aws logs tail "/aws/lambda/${LAMBDA_FUNCTION_NAME}" --follow --region "${AWS_REGION}"
```

Inspect EventBridge targets:

```bash
aws events list-targets-by-rule --name "${EVENT_RULE_NAME}" --region "${AWS_REGION}"
```

Common issues:

- `AccessDenied`: missing IAM permissions.
- No invocations: Fastly is not writing logs to the expected bucket.
- No events: S3 EventBridge notifications are not enabled.
- Fastly endpoint update fails: missing `FASTLY_API_TOKEN` permission or invalid S3 credentials.

## Operational Notes

- Fastly log delivery is near real-time but can be delayed by buffering periods.
- Costs come from S3 storage, Lambda invocations, EventBridge events, and Fastly log streaming.
