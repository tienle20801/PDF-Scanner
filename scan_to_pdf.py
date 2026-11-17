import os
import sys

import cv2
from PIL import Image

from scripts.batch_scanner import (
    balance_page_symmetry,
    compensate_strokes_and_lines,
    convert_folder_to_hd_pdf,
    detect_and_crop,
    enhance_image,
    enhance_image_bgr,
    flatten_document_surface,
    load_image_bgr,
    multipoint_border_mask_clean,
)

__all__ = [
    "balance_page_symmetry",
    "build_pdf",
    "compensate_strokes_and_lines",
    "convert_folder_to_hd_pdf",
    "detect_and_crop",
    "enhance_image",
    "enhance_image_bgr",
    "flatten_document_surface",
    "load_image_bgr",
    "multipoint_border_mask_clean",
    "process_image_to_scanned",
]


def process_image_to_scanned(image_path, enhance_mode="magic_color", auto_crop=False):
    """Process a single image into a scanned PIL Image using the full batch_scanner pipeline."""
    img = load_image_bgr(image_path)
    if auto_crop:
        img = detect_and_crop(img)
        orig_hw = img.shape[:2]
        img = multipoint_border_mask_clean(img, points_per_edge=32)
        img = enhance_image_bgr(img, mode=enhance_mode)
        img = flatten_document_surface(img)
        img = balance_page_symmetry(img, target_shape=orig_hw)
        if enhance_mode in ("bw", "grayscale"):
            return Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)).convert("L")
        return Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))
    return enhance_image(img, mode=enhance_mode)


def build_pdf(
    input_dir=".",
    output_pdf="scanned_document.pdf",
    enhance_mode="magic_color",
    auto_crop=False,
    dpi=200,
):
    """Build a multi-page PDF from images/PDFs in input_dir using the upgraded pipeline."""
    out_path = output_pdf if os.path.isabs(output_pdf) else os.path.join(input_dir, output_pdf)
    return convert_folder_to_hd_pdf(
        input_path=input_dir,
        output_pdf_path=out_path,
        mode=enhance_mode,
        auto_crop=auto_crop,
        dpi=dpi,
        multipoint_points=32,
        flatten_surface=True,
        balance_symmetry=True,
    )


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "magic_color"
    target_dir = os.path.dirname(os.path.abspath(__file__))
    ok = build_pdf(input_dir=target_dir, output_pdf="Scanned_HD_Output.pdf", enhance_mode=mode)
    sys.exit(0 if ok else 1)
