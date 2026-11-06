import type { Config } from '../config.ts';

export type ConsoleLink = { label: string; url: string };

/** Operator shortcuts on the dashboard. None of these are secrets. */
export function consoleLinks(github: Config['github']): ConsoleLink[] {
  const links: ConsoleLink[] = [
    { label: 'CloudKit Console', url: 'https://icloud.developer.apple.com/dashboard/' },
    { label: 'App Store Connect', url: 'https://appstoreconnect.apple.com/' },
    { label: 'TestFlight', url: 'https://appstoreconnect.apple.com/apps' },
  ];
  if (github) {
    links.push(
      { label: 'GitHub 저장소', url: `https://github.com/${github.repo}` },
      { label: 'GitHub Actions', url: `https://github.com/${github.repo}/actions` },
    );
  }
  links.push({ label: '지원 페이지', url: '/' });
  return links;
}
