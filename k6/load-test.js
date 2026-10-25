// k6 load test used in Module 3 to trigger CPU-based autoscale of the public APIs.
// Run: docker run --rm -i -v "$PWD":/scripts grafana/k6 run /scripts/load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m',  target: 50 },   // ramp up
    { duration: '10m', target: 100 },  // hold heavy load (> 5 min so the CPU rule can fire)
    { duration: '1m',  target: 0 },    // ramp down
  ],
};

const PREFIX = __ENV.PREFIX || 'ajitjha';
const urls = [
  `https://${PREFIX}-petservice.azurewebsites.net/petstorepetservice/v2/pet/findByStatus?status=available`,
  `https://${PREFIX}-productservice.azurewebsites.net/petstoreproductservice/v2/product/findByStatus?status=available`,
  `https://${PREFIX}-orderservice.azurewebsites.net/petstoreorderservice/v2/store/info`,
];

export default function () {
  for (const url of urls) {
    const res = http.get(url);
    check(res, { 'status is 200': (r) => r.status === 200 });
  }
  sleep(0.2);
}
