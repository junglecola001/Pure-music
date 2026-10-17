FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && chown node:node /app
COPY --chown=node:node server.js ./
COPY --chown=node:node src ./src
RUN mkdir data && chown node:node data
USER node
ENV HOST=0.0.0.0 PORT=3000 COOKIE_FILE=/app/data/netease.cookie
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD node -e "fetch('http://127.0.0.1:3000/api/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.js"]
