# HiCStream Docker Setup

Docker configuration for running the HiCStream server to serve local .hic files with Range request and CORS support.

## Quick Start

```bash
# Build and start the container
docker-compose up -d

# View logs
docker-compose logs -f

# Stop the container
docker-compose down
```

The server will be available at `http://localhost:8020`

## Configuration

### Default Setup

- **Port**: 8020
- **Mount**: Host root (`/`) mounted as read-only at `/data` in container
- **Allowed extensions**: `.hic` only
- **Directory listing**: Disabled
- **User**: Non-root user (UID 1000)

### Customization

#### Change Port

Edit `docker-compose.yml`:
```yaml
ports:
  - "9000:8020"  # Host port 9000 → Container port 8020
```

#### Change Mount Point

To serve a specific directory instead of host root:
```yaml
volumes:
  - /path/to/your/hic/files:/data:ro
```

#### Allow Additional File Types

Edit `docker-compose.yml`:
```yaml
command: >
  -d /data
  -p 8020
  --extensions .hic .cool .mcool
```

Or allow all files:
```yaml
command: >
  -d /data
  -p 8020
  --extensions '*'
```

#### Enable Directory Listing

```yaml
command: >
  -d /data
  -p 8020
  --allow-dirlist
```

## Security Features

- ✅ Non-root user inside container
- ✅ Read-only filesystem access
- ✅ Read-only container filesystem
- ✅ No new privileges allowed
- ✅ File type restrictions (default: .hic only)
- ✅ Directory listing disabled by default

## Usage Examples

### Access a .hic file

If you have a file at `/home/user/data/sample.hic` on your host:

```
http://localhost:8020/home/user/data/sample.hic
```

### Using with HiCStat

In HiCStat, enter the local file path:
```
/home/user/data/sample.hic
```

HiCStat will automatically route it through `https://hicstream.3dg.io` (or your configured proxy).

## Reverse Proxy Setup

To expose this publicly (e.g., at `https://hicstream.3dg.io`), use a reverse proxy:

### Caddy Example

```
hicstream.3dg.io {
    reverse_proxy localhost:8020
}
```

### Nginx Example

```nginx
server {
    listen 443 ssl http2;
    server_name hicstream.3dg.io;

    location / {
        proxy_pass http://localhost:8020;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Troubleshooting

### Permission denied errors

If you get permission errors accessing files, check:
1. File permissions on the host
2. SELinux/AppArmor policies
3. Container user UID (default: 1000)

### Port already in use

Change the host port in `docker-compose.yml`:
```yaml
ports:
  - "8021:8020"
```

### Container logs

```bash
docker-compose logs hicstream
```

### Rebuild after changes

```bash
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

## Development

### Run with live reload

For development, you can mount the script:
```yaml
volumes:
  - /:/data:ro
  - ./hicstream.py:/app/hicstream.py:ro
```

### Manual build and run

```bash
docker build -t hicstream .
docker run -d -p 8020:8020 -v /:/data:ro hicstream
```
