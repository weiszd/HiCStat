FROM nginx:1.27-alpine

# Remove default config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom config
COPY nginx.conf /etc/nginx/nginx.conf

# Use non-root user (nginx alpine image supports this)
# Write pid to /tmp so non-root can work
RUN chown -R nginx:nginx /var/cache/nginx /var/log/nginx /tmp

USER nginx

EXPOSE 8020
