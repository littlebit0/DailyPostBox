export interface ImapSequenceRange {
  start: number;
  end: number;
}

export function newestFirstSequenceRanges(
  totalMessages: number,
  limit: number | "all",
  firstBatchSize = 25,
  batchSize = 250
): ImapSequenceRange[] {
  if (!Number.isSafeInteger(totalMessages) || totalMessages < 0) {
    throw new RangeError("totalMessages must be a non-negative integer");
  }
  if (limit !== "all" && (!Number.isSafeInteger(limit) || limit < 0)) {
    throw new RangeError("limit must be a non-negative integer or all");
  }
  if (!Number.isSafeInteger(firstBatchSize) || firstBatchSize <= 0) {
    throw new RangeError("firstBatchSize must be a positive integer");
  }
  if (!Number.isSafeInteger(batchSize) || batchSize <= 0) {
    throw new RangeError("batchSize must be a positive integer");
  }

  let remaining = limit === "all"
    ? totalMessages
    : Math.min(totalMessages, limit);
  let end = totalMessages;
  const ranges: ImapSequenceRange[] = [];

  while (remaining > 0) {
    const maximumBatchSize = ranges.length === 0 ? firstBatchSize : batchSize;
    const currentBatchSize = Math.min(remaining, maximumBatchSize);
    const start = end - currentBatchSize + 1;
    ranges.push({ start, end });
    remaining -= currentBatchSize;
    end = start - 1;
  }

  return ranges;
}
