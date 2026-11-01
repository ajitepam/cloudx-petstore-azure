// k6 load test for CloudX Module 4 - Azure Container Apps HTTP autoscaling
// Run: k6 run load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const DOMAIN = 'whitebush-330ec858.eastus.azurecontainerapps.io';
const PET     = `https://petstorepetservice.${DOMAIN}/petstorepetservice/v2/pet/findByStatus?status=available`;
const PRODUCT = `https://petstoreproductservice.${DOMAIN}/petstoreproductservice/v2/product/findByStatus?status=available`;
const ORDER   = `https://petstoreorderservice.${DOMAIN}/petstoreorderservice/v2/store/info`;

export const options = {
  stages: [
    { duration: '30s', target: 50 },   // warm-up: 0 -> 50 virtual users
    { duration: '30s', target: 100 },  // ramp-up: 50 -> 100 virtual users
    { duration: '3m',  target: 100 },  // hold 100 users -> KEDA scales services out
    { duration: '30s', target: 0 },    // ramp-down
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],     // less than 5% errors
    http_req_duration: ['p(95)<3000'],  // 95% of requests under 3 s
  },
};

export default function () {
  // all three public APIs in parallel -> concurrent load on each service
  const res = http.batch([
    ['GET', PET,     null, { tags: { service: 'pet' } }],
    ['GET', PRODUCT, null, { tags: { service: 'product' } }],
    ['GET', ORDER,   null, { tags: { service: 'order' } }],
  ]);
  check(res[0], { 'pet 200':     (r) => r.status === 200 });
  check(res[1], { 'product 200': (r) => r.status === 200 });
  check(res[2], { 'order 200':   (r) => r.status === 200 });
  sleep(0.1);
}
