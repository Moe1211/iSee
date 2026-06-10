//
//  VisionProcessor.swift
//  isee
//
//  Created by Upmanyu Jha and Updated on 6/10/2026.
//
//  Processes camera frames using Apple's Vision framework with
//  adaptive frame-rate throttling to minimise energy use.


import Vision
import AVFoundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Controls how aggressively we throttle Vision processing.
/// Lower rates consume significantly less CPU/GPU and battery.
enum ProcessingSpeed {
    /// ≈1 FPS — default state: user is alone, just watching for a new face
    case low
    /// ≈3 FPS — warning: multiple faces, need more responsiveness
    case medium
    /// ≈5 FPS — alert: actively tracking a shoulder surfer
    case high
    
    /// Minimum wall-clock gap between processed frames.
    var interval: CFTimeInterval {
        switch self {
        case .low:    return 1.0    //  1 FPS
        case .medium: return 0.33   // ~3 FPS
        case .high:   return 0.2    //  5 FPS
        }
    }
    
    /// How many raw camera frames to skip between processed ones.
    /// Camera runs at ≈30 FPS, so skip N-1 frames per processed frame.
    var frameSkip: Int {
        switch self {
        case .low:    return 15  // process every 15th frame → ~2 Hz raw gate
        case .medium: return 6   // every 6th → ~5 Hz raw gate
        case .high:   return 3   // every 3rd → ~10 Hz raw gate (original)
        }
    }
}

/// VisionProcessor handles face detection using Apple's Vision framework.
/// Processes camera frames to detect and count faces in real-time.
///
/// Energy-saving design:
/// - **Adaptive FPS**: throttles down to 1 FPS in safe state, up to 5 FPS in alert
/// - **Two-stage gate**: frame-skip (coarse) + wall-clock interval (fine)
/// - **Throttle counters reset** on speed change to avoid a stale delay
class VisionProcessor: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var detectedFaces: [VNFaceObservation] = []
    @Published var faceCount: Int = 0
    @Published var isProcessing = false
    
    // MARK: - Private Properties
    private let sequenceRequestHandler = VNSequenceRequestHandler()
    private var faceDetectionRequest: VNDetectFaceRectanglesRequest!
    private let processingQueue = DispatchQueue(label: "vision.processing.queue", qos: .userInitiated)
    
    // Two-stage throttle: coarse frame skip + fine wall-clock gate
    private var lastProcessTime: CFTimeInterval = 0
    private var frameSkipCounter = 0
    
    /// Current processing speed.  Changing it resets the throttle counters
    /// so the new rate takes effect immediately instead of waiting for a
    /// stale skip-count or time-gate to expire.
    private var processingSpeed: ProcessingSpeed = .high {
        didSet {
            guard oldValue != processingSpeed else { return }
            lastProcessTime = 0
            frameSkipCounter = 0
        }
    }
    
    private var processingInterval: CFTimeInterval { processingSpeed.interval }
    private var frameSkipInterval: Int { processingSpeed.frameSkip }
    
    // MARK: - Initialization
    override init() {
        super.init()
        
        // Create face detection request
        self.faceDetectionRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            self?.handleFaceDetectionResults(request: request, error: error)
        }
        
        // Configure the request for optimal performance
        self.faceDetectionRequest.revision = VNDetectFaceRectanglesRequestRevision3
    }
    
    // MARK: - Public Methods
    
    /// Adjust processing speed based on the current security state.
    /// - Parameter speed: target speed; the processor will switch immediately
    func setProcessingSpeed(_ speed: ProcessingSpeed) {
        processingSpeed = speed
    }
    
    /// Process a camera frame for face detection.
    /// - Parameter sampleBuffer: The camera frame to analyze.
    func processFrame(_ sampleBuffer: CMSampleBuffer) {
        guard !isProcessing else { return }
        
        // ── Coarse gate: skip N-1 frames ──
        frameSkipCounter += 1
        guard frameSkipCounter >= frameSkipInterval else { return }
        frameSkipCounter = 0
        
        // ── Fine gate: enforce minimum wall-clock gap ──
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessTime >= processingInterval else { return }
        lastProcessTime = currentTime
        
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isProcessing = true
            }
            
            // Convert CMSampleBuffer to CVPixelBuffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
                return
            }
            
            // Create image request handler
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            
            do {
                // Perform face detection
                try imageRequestHandler.perform([self.faceDetectionRequest])
            } catch {
                #if DEBUG
                print("Face detection failed: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func handleFaceDetectionResults(request: VNRequest, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.isProcessing = false
            
            if let error = error {
                #if DEBUG
                print("Face detection error: \(error.localizedDescription)")
                #endif
                return
            }
            
            guard let observations = request.results as? [VNFaceObservation] else {
                self.detectedFaces = []
                self.faceCount = 0
                return
            }
            
            // Update detected faces and count
            self.detectedFaces = observations
            self.faceCount = observations.count
        }
    }
}

// MARK: - Face Detection Extensions
extension VisionProcessor {
    
    /// Get face bounding boxes normalized to the camera preview
    /// - Parameter previewSize: The size of the camera preview view
    /// - Returns: Array of normalized face rectangles
    func getNormalizedFaceRectangles(for previewSize: CGSize) -> [CGRect] {
        return detectedFaces.map { faceObservation in
            // Convert Vision's normalized coordinates to preview coordinates
            let boundingBox = faceObservation.boundingBox
            
            // Vision uses bottom-left origin, we need top-left
            let convertedRect = CGRect(
                x: boundingBox.origin.x,
                y: 1.0 - boundingBox.origin.y - boundingBox.height,
                width: boundingBox.width,
                height: boundingBox.height
            )
            
            // Scale to preview size
            return CGRect(
                x: convertedRect.origin.x * previewSize.width,
                y: convertedRect.origin.y * previewSize.height,
                width: convertedRect.width * previewSize.width,
                height: convertedRect.height * previewSize.height
            )
        }
    }
    
    /// Check if a specific face is likely the primary user (largest face)
    /// - Returns: The index of the primary face, or nil if no faces detected
    func getPrimaryFaceIndex() -> Int? {
        guard !detectedFaces.isEmpty else { return nil }
        
        // Find the face with the largest bounding box area
        var largestArea: CGFloat = 0
        var primaryIndex: Int = 0
        
        for (index, face) in detectedFaces.enumerated() {
            let area = face.boundingBox.width * face.boundingBox.height
            if area > largestArea {
                largestArea = area
                primaryIndex = index
            }
        }
        
        return primaryIndex
    }
}
