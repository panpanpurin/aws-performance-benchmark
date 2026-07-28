# EC2 / ECS image
FROM node:22-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --only=production

COPY . .

EXPOSE 3001

CMD ["npm", "start"]
