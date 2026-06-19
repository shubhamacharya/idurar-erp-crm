FROM node:24-alpine as build

WORKDIR /app

COPY package*.json ./

RUN npm ci --omit=dev

COPY . .

ENV DATABASE="mongodb://mongodb:27017" \
    JWT_SECRET="jwtsecret" \
    NODE_ENV="production" \
    OPENSSL_CONF="/dev/null" \
    PUBLIC_SERVER_FILE="http://backend:8888/" \
    PORT="8080"

RUN chmod +x entrypoint.sh

EXPOSE 8080

CMD ["./entrypoint.sh"]   