# CamScanner Remote MCP Integration & Local Engine Comparison Guide

This document describes how to optionally connect the third-party cloud **CamScanner Remote MCP** server to AI coding agents (Kilo CLI, Claude Desktop, Cursor / VS Code) and compares it accurately with the **100% offline macOS & Python Local Engine** included in this repository (`PDF Scanner.app`, `scripts/batch_scanner.py`, `scripts/pdf_compressor.py`, and `scripts/doc_scanner.swift`).

> ⚠️ **Privacy notice:** Local processing via `PDF Scanner.app`, `scan.sh`, and `scripts/batch_scanner.py` runs **100% offline** on your Mac with zero network calls. Enabling the external CamScanner MCP server below sends documents from your AI client to `https://ai-tools.camscanner.com/mcp`.

---

## 1. Remote Streamable HTTP MCP Endpoint

```text
https://ai-tools.camscanner.com/mcp
```

- **Protocol:** Model Context Protocol (MCP) over HTTP / SSE.
- **Capabilities:** Remote cloud enhancement, multi-language cloud OCR, document search, and cloud PDF compilation *(subject to CamScanner service availability and account terms; verify current endpoint headers against official CamScanner MCP documentation before production use)*.

---

## 2. Client Configuration Examples (macOS / Cross-Platform)

### Kilo CLI (`~/.config/kilo/kilo.jsonc` or project `kilo.json`)

```jsonc
{
  "$schema": "https://kilo.dev/config.schema.json",
  "mcp": {
    "camscanner-mcp": {
      "type": "remote",
      "url": "https://ai-tools.camscanner.com/mcp",
      "headers": {
        "X-IS-AGENT": "general"
      },
      "enabled": true
    }
  }
}
```

### Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "camscanner": {
      "url": "https://ai-tools.camscanner.com/mcp",
      "headers": {
        "X-IS-AGENT": "general"
      }
    }
  }
}
```

*(If your Claude Desktop or MCP client requires OAuth/Bearer authentication or a stdio proxy such as `mcp-remote`, consult the current official CamScanner MCP onboarding guide and supply credentials via environment variables rather than hardcoding tokens.)*

### Cursor / VS Code (`.vscode/mcp.json`)

```json
{
  "servers": {
    "camscanner-remote": {
      "name": "CamScanner Remote MCP",
      "type": "sse",
      "url": "https://ai-tools.camscanner.com/mcp",
      "headers": {
        "X-IS-AGENT": "general"
      }
    }
  }
}
```

---

## 3. Architecture Comparison: Remote Cloud MCP vs. Offline Local Engine (`v1.1.1`)

| Dimension | Remote CamScanner MCP (`ai-tools.camscanner.com`) | Local macOS Studio & Python Engine (`PDF Scanner.app` + `scripts/batch_scanner.py`) |
| :--- | :--- | :--- |
| **Execution Environment** | Cloud service (third-party servers) | Local Apple Silicon CPU / Neural Engine (macOS Vision + CoreImage + OpenCV + NumPy + Pillow + `pypdf`) |
| **Boundary Detection & Crop** | Cloud deep-learning document model | Hybrid Apple Vision `VNDetectDocumentSegmentationRequest` (`--quad-only` full-res warp) + OpenCV HSV+Otsu & Canny fallback + 128-point border clean + quality-gated 2D flattening |
| **Color & Image Modes** | Cloud filters (`Auto`, `Magic Color`, `B&W`, etc.) | `auto_color` (`magic_color` alias), `clean`, 1-bit `/FlateDecode` `bw`, `/DeviceGray` `grayscale`, and `original` |
| **OCR & Orientation** | Multi-language cloud OCR & table extraction | Built-in offline macOS Vision (`vi-VT` + `en-US`): single-pass `.accurate` corner-vector orientation detection (`0°/90°/180°/270°`) + optional searchable invisible PDF text layer (`enableOCR`) in `PDF Scanner.app` |
| **PDF Compression** | Cloud PDF processing | Offline vector-preserving compressor (`scripts/pdf_compressor.py`): preserves pure text/vector pages & original `MediaBox` while resizing/recompressing raster XObjects |
| **Measured Latency (Apple Silicon)** | Network-dependent (~500–2000 ms/page typical HTTP round-trip) | **`533.6 ms/page`** 6-stage median (`A4 @ 200 DPI`); **`5.50 s`** for 10-page 12MP batch (`0.55 s/page`, `workers=1`) |
| **Privacy & Cost** | Uploads files externally; subject to remote limits/quotas | **100% Offline**, zero watermarks, zero cloud egress, zero page quotas |

---

## 4. Recommended Hybrid Local + MCP Workflow (macOS zsh)

Use the local CLI first to clean, deskew, crop, and compile photos offline at high resolution without uploading raw camera originals, then pass the compact PDF to your AI client or MCP tool only if external cloud analysis is explicitly needed:

```bash
# Step 1: Process raw camera photos or scanned PDFs locally (100% offline)
./scan.sh "input/raw_photos" "output/Scanned_Document_HD.pdf" --mode auto_color --dpi 200

# Step 2 (optional): Vector-preserving compression to <= 5 MiB before sharing
.venv/bin/python scripts/pdf_compressor.py "output/Scanned_Document_HD.pdf" "output/Scanned_Compact.pdf" --target-mb 5.0
```
