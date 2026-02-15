FROM python:3.11-slim

# Create non-root user for security
RUN useradd -m -u 1000 -s /bin/bash hicstream

# Set working directory
WORKDIR /app

# Copy the hicstream script
COPY hicstream.py /app/hicstream.py
RUN chmod +x /app/hicstream.py

# Switch to non-root user
USER hicstream

# Expose default port
EXPOSE 8020

# Set entrypoint
ENTRYPOINT ["python3", "/app/hicstream.py"]

# Default arguments (can be overridden in docker-compose)
CMD ["-d", "/data", "-p", "8020"]
