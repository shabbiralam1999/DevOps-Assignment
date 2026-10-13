import { Queue } from "bullmq";
import IORedis from "ioredis";

// Created on first use (not at import time) so importing the app never opens a Redis connection.
let connection;
let itemQueue;

function getQueue() {
  if (!itemQueue) {
    connection = new IORedis(process.env.REDIS_URL || "redis://localhost:6379", {
      maxRetriesPerRequest: null,
    });
    connection.on("error", (err) => console.error("queue redis error:", err.message));
    itemQueue = new Queue("item-events", { connection });
  }
  return itemQueue;
}

export async function enqueueItemCreated(item) {
  await getQueue().add("item-created", item, {
    removeOnComplete: 100,
    removeOnFail: 100,
  });
}

// Lets tests and graceful shutdown release the Redis connection.
export async function closeQueue() {
  if (itemQueue) {
    await itemQueue.close();
    connection.disconnect();
  }
}
