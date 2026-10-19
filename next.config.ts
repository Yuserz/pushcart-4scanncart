import type { NextConfig } from 'next';

import withSerwistInit from '@serwist/next';

const withSerwist = withSerwistInit({
  swSrc: 'app/sw.ts',
  swDest: 'public/sw.js',
  cacheOnNavigation: true,
  reloadOnOnline: true,
  disable: process.env.NODE_ENV === 'development',
});

const nextConfig: NextConfig = {
  env: {
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    NEXT_IMAGE_PUBLIC_URL: process.env.NEXT_IMAGE_PUBLIC_URL,
    NEXT_PUBLIC_DESTINATION: process.env.NEXT_PUBLIC_DESTINATION,
    NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
    NEXT_PUBLIC_SUPABASE_TOKEN: process.env.NEXT_PUBLIC_SUPABASE_TOKEN,
  },
  images: {
    formats: ['image/avif', 'image/webp'],
    qualities: [75, 90],
    dangerouslyAllowLocalIP: true,
    remotePatterns: [new URL(`${process.env.NEXT_IMAGE_PUBLIC_URL}`)],
  },
  async redirects() {
    return [
      {
        source: '/',
        destination: `${process.env.NEXT_PUBLIC_DESTINATION}`,
        permanent: true,
      },
      // There is no /home page, but browsers reach it from history, old bookmarks or
      // another app's service worker on the same localhost port. Send it to sign-in,
      // which forwards a signed-in user to their dashboard.
      {
        source: '/home',
        destination: `${process.env.NEXT_PUBLIC_DESTINATION}`,
        permanent: false,
      },
    ];
  },
};

export default withSerwist(nextConfig);
