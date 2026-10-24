using Godot;
using System;
using System.Collections.Generic;

namespace VoxelTerrain;

/// <summary>
/// 地形生成的 C# 原生实现（阶段：generate C# 化）。
/// 覆盖 TerrainGenerator.generate_chunk 的"列剖面 + 方块填充"主体；
/// 树重放留在 GDScript（依赖 hash([seed,x,z])/RandomNumberGenerator
/// 序列与树形态算法，等价风险长尾——与"树不迁 C#"决策自洽），
/// 本类额外输出每列 height/sandy/rocky 剖面数组供其免重复算噪声。
///
/// 等价红线（GDScript float = 64 位 double）：
/// - 计算链全程 double（噪声引擎返回 float 提升，后续运算必须 double）
/// - round() 复刻 GD 的 half-away-from-zero（C# Math.Round 是银行家舍入）
/// - smoothstep 手写标准公式（与 Godot 内建实现一致）
/// - 噪声对象按同参数构建（FastNoiseLite 引擎实现，跨语言同值）
/// </summary>
public partial class NativeTerrain : RefCounted
{
    private const int GeneratorVersion = 6;
    private const int DirtLayerDepth = 3;
    private const int SandMaxHeight = 8;
    private const double CoalOreThreshold = 0.60;
    private const double IronOreThreshold = 0.68;
    private const int IronOreMaxY = 24;
    private const int OreSurfaceMargin = 4;
    private const int SeaLevel = 7;
    private const int KnotCount = 17;
    private const double MountainGateLo = 0.30;
    private const double MountainGateHi = 0.60;
    private const double MountainGain = 0.46;
    private const double DetailGain = 0.045;
    private const double RockSurfaceFrac = 0.62;
    private const double TempLapse = 0.9;
    private const double DesertTemp = 0.30;
    private const double DesertDryness = -0.10;
    private const double DesertMaxFrac = 0.45;
    private const int TreeReach = 4;

    private static readonly double[] TargetHeightFrac =
    {
        0.030, 0.055, 0.075, 0.095, 0.115, 0.135, 0.155, 0.180,
        0.205, 0.235, 0.270, 0.315, 0.370, 0.445, 0.540, 0.680, 0.900,
    };

    // 块 ID 由桥从 VoxelTypes 常量传入（不硬编码——两轮迁移三次
    // 猜错 ID，教训：常量表必须单一来源）
    private readonly int _grassId;
    private readonly int _dirtId;
    private readonly int _stoneId;
    private readonly int _bedrockId;
    private readonly int _sandId;
    private readonly int _sandstoneId;
    private readonly int _coalOreId;
    private readonly int _ironOreId;
    private readonly int _waterId;

    private readonly FastNoiseLite _continental;
    private readonly FastNoiseLite _mountainMask;
    private readonly FastNoiseLite _ridge;
    private readonly FastNoiseLite _detail;
    private readonly FastNoiseLite _temp;
    private readonly FastNoiseLite _precip;
    private readonly FastNoiseLite _coal;
    private readonly FastNoiseLite _iron;
    private readonly double[] _sourceKnots;
    private readonly int _worldHeightBlocks;

    /// blockIds 顺序：[grass, dirt, stone, bedrock, sand, sandstone,
    /// coal_ore, iron_ore, water]（桥按 VoxelTypes 常量顺序打包）。
    public NativeTerrain(long worldSeed, int worldHeightBlocks,
        Variant blockIdsV)
    {
        int[] b = blockIdsV.AsInt32Array();
        _grassId = b[0];
        _dirtId = b[1];
        _stoneId = b[2];
        _bedrockId = b[3];
        _sandId = b[4];
        _sandstoneId = b[5];
        _coalOreId = b[6];
        _ironOreId = b[7];
        _waterId = b[8];
        _worldHeightBlocks = worldHeightBlocks;
        _continental = MakeFbm(worldSeed, 0.0028, 4);
        _mountainMask = MakeFbm(worldSeed + 101, 0.0011, 3);
        _temp = MakeFbm(worldSeed + 202, 0.0016, 3);
        _precip = MakeFbm(worldSeed + 303, 0.0013, 3);
        _ridge = new FastNoiseLite
        {
            Seed = (int)(worldSeed + 404),
            NoiseType = FastNoiseLite.NoiseTypeEnum.Simplex,
            Frequency = 0.02f,
            FractalType = FastNoiseLite.FractalTypeEnum.Ridged,
            FractalOctaves = 3,
        };
        _detail = MakeFbm(worldSeed + 505, 0.05, 2);
        _coal = MakeFbm(worldSeed + 606, 0.08, 1);
        _iron = MakeFbm(worldSeed + 707, 0.09, 1);
        _sourceKnots = BuildSourceQuantiles();
        _worldHeightBlocks = worldHeightBlocks;
    }

    private static FastNoiseLite MakeFbm(long seed, double frequency, int octaves)
    {
        return new FastNoiseLite
        {
            Seed = (int)seed,
            NoiseType = FastNoiseLite.NoiseTypeEnum.Simplex,
            Frequency = (float)frequency,
            // GDScript _make_fbm 未显式设 fractal_type，默认即 FBM——
            // C# 显式写出，防默认值漂移
            FractalType = FastNoiseLite.FractalTypeEnum.Fbm,
            FractalOctaves = octaves,
        };
    }

    /// 与 GDScript _build_source_quantiles 逐位一致：24x24 固定采样点
    /// 排序后取 17 个分位节点（同坐标同噪声值，排序结果相同）。
    private double[] BuildSourceQuantiles()
    {
        var samples = new List<double>(24 * 24);
        for (int i = 0; i < 24; i++)
            for (int j = 0; j < 24; j++)
                samples.Add(_continental.GetNoise2D(i * 37 + 3, j * 41 + 13));
        samples.Sort();
        var knots = new double[KnotCount];
        for (int k = 0; k < KnotCount; k++)
        {
            int idx = RoundToInt((double)k / (KnotCount - 1) * (samples.Count - 1));
            knots[k] = samples[idx];
        }
        for (int k = 1; k < knots.Length; k++)
            if (knots[k] <= knots[k - 1])
                knots[k] = knots[k - 1] + 0.0001;
        return knots;
    }

    /// GD round()：half away from zero（C# Math.Round 是银行家舍入，禁用）。
    private static int RoundToInt(double x)
    {
        return (int)Math.Floor(x + 0.5);
    }

    /// 与 GDScript _shape_height 一致：噪声值线性映射到目标分位高度。
    private double ShapeHeight(double noiseValue)
    {
        if (noiseValue <= _sourceKnots[0])
            return TargetHeightFrac[0];
        for (int k = 1; k < _sourceKnots.Length; k++)
        {
            if (noiseValue <= _sourceKnots[k])
            {
                double denom = _sourceKnots[k] - _sourceKnots[k - 1];
                if (denom < 0.0001) denom = 0.0001;
                double t = (noiseValue - _sourceKnots[k - 1]) / denom;
                return TargetHeightFrac[k - 1]
                    + (TargetHeightFrac[k] - TargetHeightFrac[k - 1]) * t;
            }
        }
        return TargetHeightFrac[TargetHeightFrac.Length - 1];
    }

    /// Godot smoothstep(e0, e1, x) 的标准公式实现。
    private static double SmoothStep(double e0, double e1, double x)
    {
        double t = (x - e0) / (e1 - e0);
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
        return t * t * (3.0 - 2.0 * t);
    }

    private static double ClampD(double v, double lo, double hi)
    {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }

    /// 列剖面（与 GDScript column_profile 等价；返回三值元组而非字典）。
    private (int height, bool rocky, bool sandy) ColumnProfile(int wx, int wz)
    {
        double frac = ShapeHeight(_continental.GetNoise2D(wx, wz));
        double maskRaw = _mountainMask.GetNoise2D(wx, wz);
        double gate = SmoothStep(MountainGateLo, MountainGateHi, maskRaw);
        if (gate > 0.0)
        {
            double ridge01 = ClampD(
                (_ridge.GetNoise2D(wx, wz) + 1.0) * 0.5, 0.0, 1.0);
            frac += gate * ridge01 * MountainGain;
        }
        frac += _detail.GetNoise2D(wx, wz) * DetailGain;
        frac = ClampD(frac, 0.0, 1.0);
        int maxSurface = _worldHeightBlocks - 3;
        int height = RoundToInt(frac * (maxSurface - 1)) + 1;
        if (height < 1) height = 1;
        if (height > maxSurface) height = maxSurface;
        // v5：压掉齐平沙洲（height == SEA_LEVEL）
        if (height == SeaLevel)
            height = SeaLevel - 1;

        bool rocky = frac >= RockSurfaceFrac;
        double temp = _temp.GetNoise2D(wx, wz)
            - TempLapse * Math.Max(0.0, frac - 0.30);
        bool desert = !rocky && height > SandMaxHeight
            && temp > DesertTemp && frac < DesertMaxFrac
            && _precip.GetNoise2D(wx, wz) < DesertDryness;
        bool sandy = desert || height <= SandMaxHeight;
        return (height, rocky, sandy);
    }

    /// 与 GDScript _block_for_column 等价（rocky/sandy 已解包）。
    private int BlockForColumn(bool rocky, bool sandy,
        int wx, int wy, int wz, int height)
    {
        if (wy > height) return 0;
        if (wy == 0) return _bedrockId;
        if (wy == height)
        {
            if (rocky) return _stoneId;
            if (sandy || height <= SandMaxHeight) return _sandId;
            return _grassId;
        }
        if (wy >= height - DirtLayerDepth)
        {
            if (rocky) return _stoneId;
            if (sandy || height <= SandMaxHeight) return _sandstoneId;
            return _dirtId;
        }
        if (wy <= height - OreSurfaceMargin)
        {
            if (wy <= IronOreMaxY
                && _iron.GetNoise3D(wx, wy, wz) > IronOreThreshold)
                return _ironOreId;
            if (_coal.GetNoise3D(wx, wy, wz) > CoalOreThreshold)
                return _coalOreId;
        }
        return _stoneId;
    }

    /// 生成区块方块数据。返回 { ids: int[], heights: int[],
    /// sandy: byte[], rocky: byte[] }（列剖面供 GD 侧树重放复用）。
    public Variant GenerateChunk(Vector3I chunkCoord, int s)
    {
        int volume = s * s * s;
        var ids = new int[volume];
        var heights = new int[s * s];
        var sandy = new byte[s * s];
        var rocky = new byte[s * s];
        int originX = chunkCoord.X * s;
        int originY = chunkCoord.Y * s;
        int originZ = chunkCoord.Z * s;
        for (int lz = 0; lz < s; lz++)
        {
            int zOff = lz * s * s;
            for (int lx = 0; lx < s; lx++)
            {
                int wx = originX + lx;
                int wz = originZ + lz;
                var (height, isRocky, isSandy) = ColumnProfile(wx, wz);
                int colIdx = lz * s + lx;
                heights[colIdx] = height;
                sandy[colIdx] = isSandy ? (byte)1 : (byte)0;
                rocky[colIdx] = isRocky ? (byte)1 : (byte)0;
                int col = zOff + lx;
                for (int ly = 0; ly < s; ly++)
                {
                    int wy = originY + ly;
                    int blockId;
                    if (wy > height && wy <= SeaLevel)
                        blockId = _waterId;
                    else
                        blockId = BlockForColumn(isRocky, isSandy, wx, wy, wz, height);
                    ids[col + ly * s] = blockId;
                }
            }
        }
        var result = new Godot.Collections.Dictionary
        {
            ["ids"] = Variant.CreateFrom(ids),
            ["heights"] = Variant.CreateFrom(heights),
            ["sandy"] = Variant.CreateFrom(sandy),
            ["rocky"] = Variant.CreateFrom(rocky),
        };
        return Variant.CreateFrom(result);
    }
}
