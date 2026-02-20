import { config as loadDotEnv } from 'dotenv';

loadDotEnv();

export interface SitelineSettings {
  websiteKey?: string;
  endpoint?: string;
  debug: boolean;
}

export interface AppSettings {
  appName: string;
  siteline: SitelineSettings;
}

const parseBoolean = (value: string | undefined, fallback: boolean): boolean => {
  if (value === undefined) {
    return fallback;
  }

  const normalized = value.trim().toLowerCase();
  if (normalized === 'true') {
    return true;
  }

  if (normalized === 'false') {
    return false;
  }

  return fallback;
};

const sitelineSettings: SitelineSettings = {
  debug: parseBoolean(process.env.SITELINE_DEBUG?.trim(), false)
};

const sitelineWebsiteKey = process.env.SITELINE_WEBSITE_KEY?.trim();
const sitelineEndpoint = process.env.SITELINE_ENDPOINT?.trim();

if (sitelineWebsiteKey) {
  sitelineSettings.websiteKey = sitelineWebsiteKey;
}

if (sitelineEndpoint) {
  sitelineSettings.endpoint = sitelineEndpoint;
}

export const appConfig: Readonly<AppSettings> = Object.freeze({
  appName: process.env.APP_NAME?.trim() || 'siteline-fastly-s3-processor',
  siteline: sitelineSettings
});
