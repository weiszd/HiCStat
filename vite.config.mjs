import { defineConfig } from 'vite'

export default defineConfig({
    // Relative asset URLs: GitHub Pages serves the site under /HiCStat/, Cloudflare Pages at /
    base: './',
    build: {
        // juicebox.js is ~2 MB minified; one large chunk is expected
        chunkSizeWarningLimit: 4096
    }
})
