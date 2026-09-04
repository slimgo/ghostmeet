//
//  MicCaptureTests.swift
//  GhostMeetTests
//

import AVFoundation
import Foundation
import Testing
@testable import GhostMeet

@Suite("Первый канал из любого формата тапа")
struct FirstChannelLayoutTests {

    private func interleaved(_ channels: [[Float]], rate: Double = 48_000) -> AVAudioPCMBuffer {
        let count = channels[0].count
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let plane = buffer.floatChannelData![0]
        for i in 0..<count { for c in 0..<channels.count { plane[i * channels.count + c] = channels[c][i] } }
        return buffer
    }

    /// Формат, прочитанный из AudioUnit после привязки устройства, на этой машине
    /// interleaved. Первая версия возвращала `nil` — и починка -10868 превратилась
    /// бы в захват, который стартует и молчит.
    @Test("Interleaved стерео: берётся канал 0, а не чередование")
    func interleavedStereoTakesChannelZero() throws {
        let left: [Float] = [0.1, 0.2, 0.3, 0.4]
        let right: [Float] = [0.9, 0.9, 0.9, 0.9]
        let mono = try #require(MicCaptureService.firstChannel(of: interleaved([left, right])))

        #expect(mono.format.isInterleaved == false)
        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == 4)
        let samples = (0..<4).map { mono.floatChannelData![0][$0] }
        #expect(samples == left, "должен быть левый канал целиком, а не L R L R")
    }

    @Test("Interleaved моно: копия, но уже planar")
    func interleavedMonoBecomesPlanar() throws {
        let mono = try #require(MicCaptureService.firstChannel(of: interleaved([[0.5, -0.5, 0.25]])))
        #expect(mono.format.isInterleaved == false)
        #expect((0..<3).map { mono.floatChannelData![0][$0] } == [0.5, -0.5, 0.25])
    }

    /// Некоторые устройства отдают целые сэмплы; `floatChannelData` у такого
    /// буфера `nil`, и без этой ветки он был бы молча отброшен.
    @Test("Int16 приводится к float в диапазоне -1…1")
    func int16IsScaled() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        buffer.int16ChannelData![0][0] = 16_384
        buffer.int16ChannelData![0][1] = -32_768
        buffer.int16ChannelData![0][2] = 0
        let mono = try #require(MicCaptureService.firstChannel(of: buffer))
        let samples = (0..<3).map { mono.floatChannelData![0][$0] }
        #expect(abs(samples[0] - 0.5) < 0.0001)
        #expect(abs(samples[1] + 1.0) < 0.0001)
        #expect(samples[2] == 0)
    }

    @Test("Planar float моно возвращается как есть — быстрый путь не сломан")
    func planarMonoPassesThrough() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let mono = try #require(MicCaptureService.firstChannel(of: buffer))
        #expect(mono === buffer)
    }
}
