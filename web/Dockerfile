# syntax=docker/dockerfile:1

# The web client as a static site: bundled by Node, served by Caddy.
#
# VITE_API_BASE is left empty, so the client calls /api on its own origin and
# the ingress in front sends that to the API. One origin means no CORS.

FROM node:22-alpine AS build
WORKDIR /web
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build


FROM caddy:2-alpine
COPY Caddyfile /etc/caddy/Caddyfile
COPY --from=build /web/dist /srv
