from pathlib import Path


MODEL_ID = "Qwen/Qwen3-0.6B"
MODEL_REVISION = "c1899de289a04d12100db370d81485cdf75e47ca"
MAX_SEQUENCE_LENGTH = 128
MAX_NEW_TOKENS = 16
PERFORMANCE_TRIALS = 5
BENCHMARK_PROMPT = "Apple Silicon上のローカル推論について短く説明してください。"

LAB_DIR = Path(__file__).resolve().parent
MODELS_DIR = LAB_DIR / "models"
OUTPUT_DIR = LAB_DIR / "output"
PTE_PATHS = {
    "mlx_bf16": MODELS_DIR / "qwen3-0.6b-mlx-bf16.pte",
    "mlx_int4": MODELS_DIR / "qwen3-0.6b-mlx-int4.pte",
}

PROMPTS = [
    "日本の首都を一語で答えてください。",
    "1+1の答えを数字一文字だけで答えてください。",
    "次の文字列をそのまま出力してください: MLX",
]
