// EC2 / ECS long-running HTTP server
const app = require('./src/app');

const PORT = process.env.PORT || 3000;

app.listen(PORT, '0.0.0.0', () => {
  console.log(`AniLove server running on port ${PORT}`);
});
