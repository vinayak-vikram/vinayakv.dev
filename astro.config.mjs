// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://vinayakv.dev',
  output: 'static',
  markdown: {
    syntaxHighlight: 'shiki',
    shikiConfig: {
      theme: 'github-light',
    },
  },
});
