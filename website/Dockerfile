# The OpenMaé website: the static files of public/, served by nginx on port 8080 (see nginx.conf).
#
#   docker build -t openmae-website website
#   docker run --rm -p 8080:8080 openmae-website
FROM nginx:stable-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
# Readable by nginx's workers whatever the permissions were in the checkout.
RUN find /usr/share/nginx/html -type d -exec chmod 755 {} + \
 && find /usr/share/nginx/html -type f -exec chmod 644 {} +

EXPOSE 8080
