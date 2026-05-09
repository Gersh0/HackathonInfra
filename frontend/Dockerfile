FROM oven/bun:1.2.2-alpine

WORKDIR /app

COPY package.json ./
RUN bun install

COPY . .

EXPOSE 5173

CMD ["bun", "run", "dev"]
