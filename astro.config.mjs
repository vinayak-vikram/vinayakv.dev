// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://vinayakv.dev',
  output: 'static',
  markdown: {
    syntaxHighlight: 'shiki',
    shikiConfig: {
      themes: {
        light: 'github-light',
        dark: 'github-dark',
      },
      defaultColor: false,
    },
  },
});
