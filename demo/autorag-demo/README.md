# AutoRAG Demo (Technology Preview)

Automated RAG pipeline optimization — finds the best retrieval-augmented generation configuration for your documents.

## What AutoRAG Does

Provide documents and test questions, and AutoRAG automatically:
- Tests combinations of chunking, embedding, retrieval, and generation settings
- Evaluates each combination against your test data
- Ranks RAG patterns on a leaderboard by evaluation metrics
- Generates indexing and inference notebooks for the best patterns

## Deploy

```bash
./deploy.sh                    # Deploy infrastructure
./deploy.sh -n my-namespace    # Custom namespace
./deploy.sh --delete           # Remove
```

This deploys:
- MinIO (document storage + pipeline artifacts)
- Milvus vector database (required by AutoRAG — inline Milvus not supported)
- Pipeline Server (DSPA for Kubeflow Pipelines)
- S3 data connection with sample documents
- **RHOAI 3.5**: OGX Server (replaces LlamaStack)
- **RHOAI 3.4**: LlamaStack (auto-detected)

## Version Compatibility

The deploy script auto-detects your RHOAI version:

| RHOAI Version | Component | API | DSC Setting |
|---|---|---|---|
| **3.5+** | OGX Server | `ogx.io/v1beta1` OGXServer | `ogx: Managed` |
| **3.4** | LlamaStack | `llamastack.io/v1alpha1` LlamaStackDistribution | `llamastackoperator: Managed` |

> **Note**: OGX and LlamaStack are mutually exclusive in RHOAI 3.5. The DSC must have `llamastackoperator: Removed` when `ogx: Managed`.

## Prerequisites

AutoRAG has the heaviest infrastructure requirements of any RHOAI feature:

| Requirement | How to Enable |
|------------|--------------|
| OGX component (3.5) or Llama Stack Operator (3.4) | `ogx: Managed` or `llamastackoperator: Managed` in DSC (auto-enabled by deploy script) |
| OGX/LlamaStack Instance | Created by deploy script with foundation + embedding models |
| Embedding Model | Deploy BAAI/bge-m3 (recommended) via OGX/LlamaStack |
| Foundation Model | Any vLLM-served LLM registered with OGX/LlamaStack |
| Remote Milvus | Deployed by this script |
| AI Pipelines | `aipipelines: Managed` in DSC |
| Gen AI Studio | `genAiStudio: true` in dashboard config |

## Post-Deploy Manual Setup

After running `deploy.sh`, complete these steps in the RHOAI dashboard:

### 1. Create OGX/LlamaStack Connection

1. Dashboard > autorag-demo project > Connections
2. Add connection: **OGX Server** (3.5) or **Llama Stack** (3.4)
   - Base URL: shown in deploy script output
   - API Key: your API key or leave empty

### 2. Create AutoRAG Optimization Run

1. Dashboard > **Develop and train > AutoRAG**
2. Click **Create run**
3. Configure:
   - S3 Connection: `AutoRAG Documents`
   - OGX/Llama Stack Connection: (from step 1)
   - Optimization metric: e.g. **Answer correctness**
   - Upload test data: `sample-data/test-data.json`
4. Optional: Limit models (max 3 foundation + 2 embedding to avoid failures)
5. Click **Create run**

### 3. Evaluate and Use

1. Wait for the run to complete
2. Review RAG patterns on the leaderboard
3. Compare patterns by Sample Q&A responses
4. Save indexing and inference notebooks for the best pattern
5. Run notebooks in a workbench

## Sample Data

### Documents (`sample-data/docs/`)
Three markdown documents covering OpenShift AI topics:
- `openshift-ai-overview.md` — Platform overview and architecture
- `model-serving-guide.md` — Serving runtimes and deployment modes
- `pipelines-and-training.md` — Pipelines, AutoML, and distributed training

### Test Data (`sample-data/test-data.json`)
10 question-answer pairs for evaluating RAG quality, covering topics like:
- Serving runtimes and deployment modes
- MaaS and API management
- AutoML workflow
- Hardware Profiles and GPU support

## Evaluation Metrics

| Metric | What It Measures |
|--------|-----------------|
| Answer correctness | Factual accuracy of generated answers |
| Context correctness | Relevance of retrieved documents |
| Faithfulness | Whether answers are grounded in retrieved context |
| Answer relevance | Whether answers address the question |

## Limitations (Technology Preview)

- English language documents only (3.5 adds multilingual TP)
- Remote Milvus only (inline not supported)
- Max 3 foundation models + 2 embedding models per run
- No OCR or table detection for PDFs
- No image processing in documents
