pub const DIM: usize = 14;
pub const BLOCK_SIZE: usize = 8;
pub const SCALE: f32 = 10000.0;
pub const SENTINEL_I16: i16 = -10000;

// K=4096 + sample=65536 + 6 iters: clusters menores (mais deles) maximizam
// recall do fast tier sem depender tanto do adaptive.
pub const NUM_CENTROIDS: usize = 4096;
pub const SAMPLE_SIZE: usize = 65_536;
pub const KMEANS_ITERS: usize = 6;
pub const KMEANS_SEED: u64 = 0xdead_beef_cafe_babe;

// fast=8/full=32 + adaptive {1..4}: testado E=0 estavel. fast<8 perde 1 FN.
// Penalidade por 1 FN = ~180pts (peso 3) — sempre prioritario manter fast=8.
pub const FAST_NPROBE: usize = 8;
pub const FULL_NPROBE: usize = 32;
pub const ADAPTIVE_MIN: u8 = 1;
pub const ADAPTIVE_MAX: u8 = 4;

pub const TOP_K: usize = 5;
pub const FRAUD_THRESHOLD: u8 = 3;

pub const WARMUP_ITERS: usize = 2000;
