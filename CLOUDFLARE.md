# Cloudflare Pages Deployment

HiCStat can be deployed to Cloudflare Pages for global CDN distribution and automatic HTTPS.

## Automatic Deployment via GitHub Actions

The workflow at `.github/workflows/cloudflare-pages.yml` automatically deploys to Cloudflare Pages on every push to `master`.

### Setup Steps

1. **Get your Cloudflare Account ID:**
   - Log in to the [Cloudflare Dashboard](https://dash.cloudflare.com)
   - Select your account
   - Copy your Account ID from the right sidebar (or from the URL)

2. **Create a Cloudflare API Token:**
   - Go to [API Tokens](https://dash.cloudflare.com/profile/api-tokens)
   - Click "Create Token"
   - Use the "Edit Cloudflare Workers" template or create a custom token with:
     - Permissions: `Account - Cloudflare Pages - Edit`
   - Copy the token (you won't see it again!)

3. **Add GitHub Secrets:**
   - Go to your GitHub repo → Settings → Secrets and variables → Actions
   - Add two new repository secrets:
     - `CLOUDFLARE_API_TOKEN` = your API token from step 2
     - `CLOUDFLARE_ACCOUNT_ID` = your Account ID from step 1

4. **Push to master or manually trigger the workflow:**
   - The workflow will create a Cloudflare Pages project named `hicstat`
   - Your site will be available at `https://hicstat.pages.dev`
   - You can configure a custom domain in the Cloudflare Pages dashboard

## Local Deployment with Wrangler

Install wrangler CLI:
```bash
npm install -g wrangler
# or
pnpm add -g wrangler
```

Authenticate:
```bash
wrangler login
```

Deploy manually:
```bash
wrangler pages deploy . --project-name=hicstat
```

## SPA Routing

The `_redirects` file handles deep linking (e.g., `/ENCFF090JFB` → `/?q=ENCFF090JFB`) natively on Cloudflare Pages. No need for the `404.html` workaround required on GitHub Pages.

## Custom Domain

After deployment, you can add a custom domain:
1. Go to Workers & Pages → hicstat → Custom domains
2. Add your domain and configure DNS as prompted

## Benefits of Cloudflare Pages

- Global CDN with edge caching
- Automatic HTTPS
- Faster than GitHub Pages in most regions
- Built-in analytics and Web Analytics
- Preview deployments for pull requests
- Native `_redirects` and `_headers` support
