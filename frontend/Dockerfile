FROM node:24-alpine AS build

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

ENV VITE_BACKEND_SERVER=http://0.0.0.0:8080/
ENV VITE_DEV_REMOTE=remote
ENV PUBLIC_SERVER_FILE=http://0.0.0.0:8888/

RUN npm run build

FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]