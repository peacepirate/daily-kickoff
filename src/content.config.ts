import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const digestSchema = z.object({
  title: z.string(),
  date: z.coerce.date(),
  theme: z.enum(['ai', 'leadership', 'local-llm', 'mythology', 'richmond', 'rva-events']),
  format: z.enum(['daily', 'weekly-synthesis']).default('daily'),
  tldr: z.string(),
  itemCount: z.number(),
  readTimeMinutes: z.number(),
  sources: z
    .array(z.object({ title: z.string(), url: z.string().url() }))
    .default([]),
  actions: z
    .object({
      try: z.array(z.string()).default([]),
      share: z
        .array(z.object({ what: z.string(), who: z.string() }))
        .default([]),
      readDeeper: z.array(z.string()).default([]),
      skip: z.array(z.string()).default([]),
    })
    .default({ try: [], share: [], readDeeper: [], skip: [] }),
});

export const collections = {
  ai: defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/ai' }),
    schema: digestSchema,
  }),
  leadership: defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/leadership' }),
    schema: digestSchema,
  }),
  mythology: defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/mythology' }),
    schema: digestSchema,
  }),
  richmond: defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/richmond' }),
    schema: digestSchema,
  }),
  'local-llm': defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/local-llm' }),
    schema: digestSchema,
  }),
  'rva-events': defineCollection({
    loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/rva-events' }),
    schema: digestSchema,
  }),
};
