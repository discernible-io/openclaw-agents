# Pinned base (tag + manifest-list digest). Bump both when upgrading nginx.
FROM docker.io/nginx:1.31.0-alpine@sha256:f105e3f12187c58ddc3acd09bbe4b9e4a9ab1df855d3d0e511b641077b5e988e

ARG NODE_ENV=main

RUN apk add --no-cache openssl \
 && rm /etc/nginx/conf.d/default.conf \
 && mkdir -p /app/certs /etc/nginx/inc

COPY nginx/nginx.${NODE_ENV}.conf /etc/nginx/nginx.conf
COPY nginx/inc/ /etc/nginx/inc/

RUN chown -R nginx:nginx /etc/nginx/nginx.conf /etc/nginx/inc /var/cache/nginx /var/log/nginx /etc/nginx/conf.d /app

USER nginx
EXPOSE 9443

CMD ["nginx", "-g", "daemon off;"]
