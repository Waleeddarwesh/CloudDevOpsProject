FROM node:22-alpine

WORKDIR /app

# Upgrade npm to fix CVE-2026-59873 in bundled node-tar
RUN npm install -g npm@latest

COPY package*.json ./
RUN npm install --omit=dev

COPY . .

EXPOSE 3000

CMD ["npm", "start"]
