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
    private const int GeneratorVersion = 8;
    private const int DirtLayerDepth = 3;
    // v9 高度联动：海平面/沙线/铁矿带随世界高度派生（构造期算；
    // GD 侧 TerrainGenerator.sea_level_for 位同步——48 高=7 逐格一致，
    // 其余 H/8）
    private readonly int _seaLevel;
    private readonly int _sandMaxHeight;
    private readonly int _ironOreMaxY;
    private const int OreSurfaceMargin = 4;
    // v7 洞穴与矿脉（Minetest cavegen/mg_ore 算法移植）。
    // 阈值按归一化噪声实测分位标定（探针：W=0.88 → 隧道 ~3.5%、
    // 剖面中位 3 格可通行；煤 ~2.1%、铁 ~0.74%）——Minetest 的
    // 0.09/0.16/0.30 依赖其噪声 scale=3 的宽值域，FastNoiseLite
    // 归一输出下不可直接套用。
    private const double CaveWidth = 0.88;
    private const double CaveFreq = 1.0 / 48.0;
    private const int CaveOctaves = 2;
    private const double CheeseFreq = 1.0 / 64.0;
    private const int CheeseOctaves = 2;
    private const double CheeseThreshold = 0.58;
    private const int CheeseMinDepth = 8;
    private const double VeinFreq = 1.0 / 16.0;
    private const int VeinOctaves = 1;
    private const double VeinJitter = 0.04;
    private const double CoalVeinValue = 0.92;
    private const double IronVeinValue = 0.965;
    private const int KnotCount = 17;
    // v8 地形塑形（Epic-Terrain 配比，巨型档=其尺度 ÷2）
    private const double ContinentFreq = 1.0 / 4096.0;
    private const int ContinentOctaves = 6;
    private const double MountainMaskFreq = 1.0 / 2048.0;
    private const double RidgeFreq = 1.0 / 1024.0;
    private const int RidgeOctaves = 5;
    private const double MountainGain = 0.46;
    private const double ErodeFreq = 1.0 / 1024.0;
    private const double ErodeGain1 = 0.5;
    private const double ErodeGain2 = 0.3;
    private const double ErodeGain3 = 0.17;
    private const double ErodeGain4 = 0.08;
    private const double CoastRiseLo = 0.06;
    private const double CoastRiseHi = 0.11;
    private const double CoastFallLo = 0.24;
    private const double CoastFallHi = 0.34;
    private const double CoastErodeGain = 0.07;
    private const double InlandErodeGain = 0.03;
    private const double RiverFreq = 1.0 / 2048.0;
    private const int RiverOctaves = 4;
    private const double RiverModFreq = 1.0 / 1024.0;
    private const double RiverBand = 0.001;
    private const double RiverFrac = 0.085;
    private const double RiverBase = 0.4;
    private const double MountainGateLo = 0.30;
    private const double MountainGateHi = 0.60;
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
    private readonly FastNoiseLite _e0;
    private readonly FastNoiseLite _e1;
    private readonly FastNoiseLite _e2;
    private readonly FastNoiseLite _e3;
    private readonly FastNoiseLite _e4;
    private readonly FastNoiseLite _river1;
    private readonly FastNoiseLite _river2;
    private readonly FastNoiseLite _temp;
    private readonly FastNoiseLite _precip;
    private readonly FastNoiseLite _coal;
    private readonly FastNoiseLite _iron;
    // v7 洞穴与矿脉噪声（隧道双等值线 / 大洞厅 / 细脉双等值线）
    private readonly FastNoiseLite _cave1;
    private readonly FastNoiseLite _cave2;
    private readonly FastNoiseLite _cheese;
    private readonly FastNoiseLite _vein1;
    private readonly FastNoiseLite _vein2;
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
        _seaLevel = worldHeightBlocks <= 48 ? 7 : worldHeightBlocks / 8;
        _sandMaxHeight = _seaLevel + 1;
        _ironOreMaxY = _seaLevel + 13;
        _continental = MakeFbm(worldSeed, ContinentFreq, ContinentOctaves);
        _mountainMask = MakeFbm(worldSeed + 101, MountainMaskFreq, 3);
        _temp = MakeFbm(worldSeed + 202, MountainMaskFreq, 3);
        _precip = MakeFbm(worldSeed + 303, MountainMaskFreq, 3);
        _ridge = new FastNoiseLite
        {
            Seed = (int)(worldSeed + 404),
            NoiseType = FastNoiseLite.NoiseTypeEnum.Simplex,
            Frequency = (float)RidgeFreq,
            FractalType = FastNoiseLite.FractalTypeEnum.Ridged,
            FractalOctaves = RidgeOctaves,
        };
        _e0 = MakeFbm(worldSeed + 505, ErodeFreq, 1);
        _e1 = MakeFbm(worldSeed + 515, ErodeFreq * 2.0, 1);
        _e2 = MakeFbm(worldSeed + 525, ErodeFreq * 4.0, 1);
        _e3 = MakeFbm(worldSeed + 535, ErodeFreq * 8.0, 1);
        _e4 = MakeFbm(worldSeed + 545, ErodeFreq * 16.0, 1);
        _river1 = MakeFbm(worldSeed + 624, RiverFreq, RiverOctaves);
        _river2 = MakeFbm(worldSeed + 634, RiverModFreq, 3);
        _coal = MakeFbm(worldSeed + 606, 0.08, 1);
        _iron = MakeFbm(worldSeed + 707, 0.09, 1);
        _cave1 = MakeFbm(worldSeed + 808, CaveFreq, CaveOctaves);
        _cave2 = MakeFbm(worldSeed + 909, CaveFreq, CaveOctaves);
        _cheese = MakeFbm(worldSeed + 1010, CheeseFreq, CheeseOctaves);
        _vein1 = MakeFbm(worldSeed + 1111, VeinFreq, VeinOctaves);
        _vein2 = MakeFbm(worldSeed + 1212, VeinFreq, VeinOctaves);
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
    /// 采样步长 911/929（v8 大陆波长 4096 → 窗 ~20000 格 ≈ 5 波长；
    /// 小窗会让分位节点挤成一点，全图高度塌到低端）。
    private double[] BuildSourceQuantiles()
    {
        var samples = new List<double>(24 * 24);
        for (int i = 0; i < 24; i++)
            for (int j = 0; j < 24; j++)
                samples.Add(_continental.GetNoise2D(i * 911 + 3, j * 929 + 13));
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
    /// v8 层序：分位匹配大陆 → 山系掩码×脊状山形 → Epic 侵蚀链
    /// （海岸带全幅/内陆轻调制）→ 河流窄带下切 → 气候群系。
    private (int height, bool rocky, bool sandy) ColumnProfile(int wx, int wz)
    {
        double frac = ShapeHeight(_continental.GetNoise2D(wx, wz));
        double maskRaw = _mountainMask.GetNoise2D(wx, wz);
        double gate = SmoothStep(MountainGateLo, MountainGateHi, maskRaw);
        if (gate > 0.0)
        {
            // FNL Ridged 实测 [-0.62,1]，截 [0,1] 后平方——压谷抬峰：
            // 不平方时输出均值 ~0.4，山系内部整体抬升成裸岩高原；
            // 平方后只有脊线附近满幅，山系=线状峰峦+谷地
            double ridge01 = ClampD(_ridge.GetNoise2D(wx, wz), 0.0, 1.0);
            ridge01 *= ridge01;
            frac += gate * ridge01 * MountainGain;
        }
        // Epic 式侵蚀链：大波长主体 + 逐级小系数扰动
        double e = _e0.GetNoise2D(wx, wz)
            + Math.Abs(_e1.GetNoise2D(wx, wz)) * ErodeGain1
            + Math.Abs(_e2.GetNoise2D(wx, wz)) * ErodeGain2
            + Math.Abs(_e3.GetNoise2D(wx, wz)) * ErodeGain3
            + Math.Abs(_e4.GetNoise2D(wx, wz)) * ErodeGain4;
        double coast = SmoothStep(CoastRiseLo, CoastRiseHi, frac)
            * (1.0 - SmoothStep(CoastFallLo, CoastFallHi, frac));
        frac += e * (coast * CoastErodeGain + InlandErodeGain);
        // 河流：原始 fbm 取 abs 的过零窄带，只在陆上下切
        double rn = Math.Abs(_river1.GetNoise2D(wx, wz));
        if (rn < RiverBand && frac > RiverFrac)
        {
            double rw = ClampD(_river2.GetNoise2D(wx, wz), 0.0, 1.0);
            double band = 1.0 - rn / RiverBand;
            double depth = band * (RiverBase + (1.0 - RiverBase) * rw);
            frac += (RiverFrac - frac) * Math.Min(depth, 1.0);
        }
        frac = ClampD(frac, 0.0, 1.0);
        int maxSurface = _worldHeightBlocks - 3;
        int height = RoundToInt(frac * (maxSurface - 1)) + 1;
        if (height < 1) height = 1;
        if (height > maxSurface) height = maxSurface;
        // v5：压掉齐平沙洲（height == SEA_LEVEL）
        if (height == _seaLevel)
            height = _seaLevel - 1;

        bool rocky = frac >= RockSurfaceFrac;
        double temp = _temp.GetNoise2D(wx, wz)
            - TempLapse * Math.Max(0.0, frac - 0.30);
        bool desert = !rocky && height > _sandMaxHeight
            && temp > DesertTemp && frac < DesertMaxFrac
            && _precip.GetNoise2D(wx, wz) < DesertDryness;
        bool sandy = desert || height <= _sandMaxHeight;
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
            if (sandy || height <= _sandMaxHeight) return _sandId;
            return _grassId;
        }
        if (wy >= height - DirtLayerDepth)
        {
            if (rocky) return _stoneId;
            if (sandy || height <= _sandMaxHeight) return _sandstoneId;
            return _dirtId;
        }
        // v7 洞穴与矿脉（地表保护层内不挖——防满地天窗；基岩上留层）
        if (wy <= height - OreSurfaceMargin && wy >= 1)
        {
            if (IsCave(wx, wy, wz, height))
                return 0;
            int ore = OreVein(wx, wy, wz);
            if (ore != 0)
                return ore;
        }
        return _stoneId;
    }

    /// 隧道：双 3D 噪声等值线交叉（Minetest cavegen）；大洞厅：低频
    /// 3D 噪声超阈值（更深处）。
    private bool IsCave(int wx, int wy, int wz, int height)
    {
        double d1 = 1.0 - Math.Abs(_cave1.GetNoise3D(wx, wy, wz));
        double d2 = 1.0 - Math.Abs(_cave2.GetNoise3D(wx, wy, wz));
        if (d1 * d2 > CaveWidth)
            return true;
        if (wy <= height - CheeseMinDepth
            && _cheese.GetNoise3D(wx, wy, wz) > CheeseThreshold)
            return true;
        return false;
    }

    /// GD 侧 _hash_unit 的位同步镜像：int64 乘异或环绕 + abs 取模。
    private static double HashUnit(int x, int y, int z)
    {
        long h = (long)x * 73856093L ^ (long)y * 19349663L
            ^ (long)z * 83492791L;
        h = Math.Abs(h) % 65536;
        return h / 65536.0;
    }

    /// 矿脉细脉（Minetest mg_ore OreVein）：vein 双噪声等值线交叉
    /// + hash 抖动控制厚度；煤浅带、铁更深。
    private int OreVein(int wx, int wy, int wz)
    {
        double d1 = 1.0 - Math.Abs(_vein1.GetNoise3D(wx, wy, wz));
        double d2 = 1.0 - Math.Abs(_vein2.GetNoise3D(wx, wy, wz));
        double jitter = HashUnit(wx, wy, wz) * 2.0 - 1.0;
        double value = d1 * d2 + jitter * VeinJitter;
        if (value > IronVeinValue && wy <= _ironOreMaxY)
            return _ironOreId;
        if (value > CoalVeinValue)
            return _coalOreId;
        return 0;
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
                    if (wy > height && wy <= _seaLevel)
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

    /// 列足迹地表高度区间（v9 垂直流式加载带的依据）：(s+2)² 外扩
    /// 一格——悬崖恰在列边界时，崖壁属于高列方块却面向低列，外圈
    /// 把低列高度纳入高列区间，保证崖壁所在层被加载（否则崖壁中段
    /// 不加载=悬崖开洞）。返回 (minH, maxH)。
    public Vector2I ColumnSurfaceRange(int chunkX, int chunkZ, int s)
    {
        int minH = int.MaxValue;
        int maxH = int.MinValue;
        int ox = chunkX * s - 1;
        int oz = chunkZ * s - 1;
        for (int z = 0; z < s + 2; z++)
        {
            for (int x = 0; x < s + 2; x++)
            {
                var (h, _, _) = ColumnProfile(ox + x, oz + z);
                if (h < minH) minH = h;
                if (h > maxH) maxH = h;
            }
        }
        return new Vector2I(minH, maxH);
    }

    // ---- 远景山壳 v2（方块风 LOD，Distant Horizons 式）----
    // 用户定调：LOD 必须保持体素语言——每级用更粗的"方块"渲染
    //（格距 4/8/16/32，垂直量化 S/2），近处方块阶梯、远处大块方
    // 柱，与 chunk 体素同一视觉语言（平滑高度场网格像"平面贴图"，
    // 实机否决）。方形环带：各级都是切比雪夫格距 [60,128) 的环
    //（×S = 240-512 / 480-1024 / 960-2048 / 1920-4096），全局对齐
    // 网格（格坐标×S=世界坐标，重建不游移）。格高 = 2×2 采样最大
    // 值向下量化；水=整片环形水面 4 矩形（sea-0.1，消逐格顶面）；
    // 陆格出顶面 + 侧壁（邻居更低才出，等截面 run 合并），环带内外
    // 缘裙壁到 y=0 防级间缝。光照沿用 ShaderMaterial：NORMAL 轴
    // 对齐，太阳漫反射天然给出面向亮度差（参考图效果）。
    private static readonly int[] ShellLevels = { 4, 8, 16, 32 };
    private const int ShellRingInner = 60;
    private const int ShellRingOuter = 128;

    public ArrayMesh GenerateShellMesh(int centerX, int centerZ)
    {
        var mesh = new ArrayMesh();
        // 整片圆盘水面（sea-0.3，略低于 chunk 水面防共面闪；内缘伸
        // 进 chunk 圈藏在水下，外缘 4096）——水无 LOD 层级差异，曾
        // 按级出 4 矩形框：相邻级 [60×2S,128×S] 有 8S 宽共面重叠环
        // 带 z-fighting，框缘在低机位多层交织成放射扇纹（实机三轮）
        {
            var verts = new List<Vector3>();
            var norms = new List<Vector3>();
            var cols = new List<Color>();
            var idxs = new List<int>();
            const int SEG = 96;
            float rIn = 200f;
            float rOut = ShellRingOuter * 32f;
            float wy = _seaLevel - 0.3f;
            var wcol = new Color(0.32f, 0.40f, 0.50f);
            for (int k = 0; k < SEG; k++)
            {
                float a0 = MathF.Tau * k / SEG;
                float a1 = MathF.Tau * (k + 1) / SEG;
                int v0 = verts.Count;
                verts.Add(new Vector3(
                    centerX + MathF.Cos(a0) * rIn, wy,
                    centerZ + MathF.Sin(a0) * rIn));
                verts.Add(new Vector3(
                    centerX + MathF.Cos(a0) * rOut, wy,
                    centerZ + MathF.Sin(a0) * rOut));
                verts.Add(new Vector3(
                    centerX + MathF.Cos(a1) * rOut, wy,
                    centerZ + MathF.Sin(a1) * rOut));
                verts.Add(new Vector3(
                    centerX + MathF.Cos(a1) * rIn, wy,
                    centerZ + MathF.Sin(a1) * rIn));
                for (int t = 0; t < 4; t++)
                {
                    norms.Add(Vector3.Up);
                    cols.Add(wcol);
                }
                idxs.Add(v0); idxs.Add(v0 + 2); idxs.Add(v0 + 1);
                idxs.Add(v0 + 1); idxs.Add(v0 + 2); idxs.Add(v0 + 3);
            }
            var arrays = new Godot.Collections.Array();
            arrays.Resize((int)Mesh.ArrayType.Max);
            arrays[(int)Mesh.ArrayType.Vertex] =
                Variant.CreateFrom(verts.ToArray());
            arrays[(int)Mesh.ArrayType.Normal] =
                Variant.CreateFrom(norms.ToArray());
            arrays[(int)Mesh.ArrayType.Color] =
                Variant.CreateFrom(cols.ToArray());
            arrays[(int)Mesh.ArrayType.Index] =
                Variant.CreateFrom(idxs.ToArray());
            mesh.AddSurfaceFromArrays(
                Mesh.PrimitiveType.Triangles, arrays);
        }
        foreach (int S in ShellLevels)
        {
            int W = ShellRingOuter * 2;
            int vs = Math.Max(1, S / 2);
            int q = Math.Max(1, S / 4);
            var tops = new int[W * W];
            var biome = new byte[W * W];   // 0 水 1 草 2 岩 3 沙
            var tint = new float[W * W];
            var inRing = new bool[W * W];
            for (int cz = 0; cz < W; cz++)
            for (int cx = 0; cx < W; cx++)
            {
                // 圆环判定（欧氏半径）：方环的角区比边区远 √2——雾
                // 化梯度沿对角突变，透视下呈放射状亮楔穿水穿山（海边
                // 低机位实机复现）；圆环雾梯度平滑（DH 同款）。格仍
                // 方形对齐（判定圆、格方）
                int ddx = cx - ShellRingOuter;
                int ddz = cz - ShellRingOuter;
                int r2 = ddx * ddx + ddz * ddz;
                if (r2 < ShellRingInner * ShellRingInner
                    || r2 >= ShellRingOuter * ShellRingOuter)
                    continue;
                int ci = cz * W + cx;
                inRing[ci] = true;
                int bx = centerX + (cx - ShellRingOuter) * S;
                int bz = centerZ + (cz - ShellRingOuter) * S;
                int hMax = int.MinValue;
                int grass = 0, rock = 0, sand = 0, waterN = 0;
                for (int sz = 0; sz < 2; sz++)
                for (int sx = 0; sx < 2; sx++)
                {
                    var (h, isRocky, isSandy) = ColumnProfile(
                        bx + (sx == 0 ? q : S - 1 - q),
                        bz + (sz == 0 ? q : S - 1 - q));
                    if (h > hMax) hMax = h;
                    if (h <= _seaLevel) waterN++;
                    else if (isRocky) rock++;
                    else if (isSandy) sand++;
                    else grass++;
                }
                tint[ci] = (float)_e4.GetNoise2D(bx, bz);
                if (waterN == 4)
                {
                    biome[ci] = 0;
                    tops[ci] = _seaLevel - 1;
                }
                else if (waterN > 0)
                {
                    // 半水格（2×2 采样部分水）：曾按陆格量化 max(hq,sea)
                    // ——浅滩区大量格顶恰好=海平面，连成贴水方块层盖在
                    // 水面圆盘之上（顶点色明暗拼块，"水的方块拼贴"实机
                    // 八轮定位）。整格藏水下 2 格，滩面由周围全陆格表达
                    biome[ci] = rock >= sand && rock >= grass ? (byte)2
                        : sand >= grass ? (byte)3 : (byte)1;
                    tops[ci] = _seaLevel - 2;
                }
                else
                {
                    biome[ci] = rock >= sand && rock >= grass ? (byte)2
                        : sand >= grass ? (byte)3 : (byte)1;
                    int hq = hMax / vs * vs;
                    // 全陆滩格至少露出一个量化步（曾 max(hq,sea)：
                    // 量化恰=海平面的滩格贴水成方块层同病）
                    tops[ci] = Math.Max(hq, _seaLevel + vs);
                }
            }

            var verts = new List<Vector3>();
            var norms = new List<Vector3>();
            var cols = new List<Color>();
            var idxs = new List<int>();

            void PushQuad(Vector3 a, Vector3 b, Vector3 c, Vector3 d,
                Vector3 n, Color col)
            {
                int v0 = verts.Count;
                verts.Add(a); verts.Add(b); verts.Add(c); verts.Add(d);
                norms.Add(n); norms.Add(n); norms.Add(n); norms.Add(n);
                cols.Add(col); cols.Add(col); cols.Add(col); cols.Add(col);
                idxs.Add(v0); idxs.Add(v0 + 2); idxs.Add(v0 + 1);
                idxs.Add(v0 + 1); idxs.Add(v0 + 2); idxs.Add(v0 + 3);
            }

            Color Base(byte b, float t)
            {
                float k = 1.0f + 0.08f * t;
                switch (b)
                {
                    case 2: return new Color(
                        0.50f * k, 0.48f * k, 0.46f * k);
                    case 3: return new Color(
                        0.72f * k, 0.66f * k, 0.49f * k);
                    default: return new Color(
                        0.24f * k, 0.36f * k, 0.18f * k);
                }
            }

            // 陆格顶面
            for (int cz = 0; cz < W; cz++)
            for (int cx = 0; cx < W; cx++)
            {
                int ci = cz * W + cx;
                if (!inRing[ci] || biome[ci] == 0)
                    continue;
                float x0 = centerX + (cx - ShellRingOuter) * (float)S;
                float z0 = centerZ + (cz - ShellRingOuter) * (float)S;
                float y = tops[ci];
                PushQuad(new Vector3(x0, y, z0),
                    new Vector3(x0 + S, y, z0),
                    new Vector3(x0, y, z0 + S),
                    new Vector3(x0 + S, y, z0 + S),
                    Vector3.Up, Base(biome[ci], tint[ci]));
            }

            // 侧壁：4 方向；同行等(顶,底,群系) run 合并。环带外缘
            // 邻居未知 → 裙壁到 y=0（级间缝防护，雾中不可见）
            int[] dxs = { 1, -1, 0, 0 };
            int[] dzs = { 0, 0, 1, -1 };
            for (int dir = 0; dir < 4; dir++)
            {
                int dx = dxs[dir], dz = dzs[dir];
                var n = new Vector3(dx, 0, dz);
                for (int a = 0; a < W; a++)
                {
                    int runStart = -1;
                    int runTop = 0, runBot = 0;
                    byte runBiome = 0;
                    float runX0 = 0, runZ0 = 0;
                    int runB = 0;
                    for (int b = 0; b <= W; b++)
                    {
                        int cx = dx != 0 ? b : a;
                        int cz = dz != 0 ? b : a;
                        int ci = -1;
                        if (b < W)
                        {
                            ci = cz * W + cx;
                            if (!inRing[ci] || biome[ci] == 0)
                                ci = -1;
                        }
                        bool wall = false;
                        int yt = 0, yb = 0;
                        if (ci >= 0)
                        {
                            int ni = (cz + dz) * W + (cx + dx);
                            bool nbOk = cx + dx >= 0 && cx + dx < W
                                && cz + dz >= 0 && cz + dz < W
                                && inRing[ni];
                            // 出环带邻居（级间边界）：裙深=一级量化步
                            //（S）而非 y=0——曾落到 0：相邻两级的裙壁
                            // 背对背从地底拔起，边界成深谷缝，方形环带
                            // 边界在低机位透视下呈放射状楔形暗带穿山
                            //（实机截图两轮实锤）。S 深的裙足够盖住级
                            // 间量化高差，残余由雾吞；不低于海平面下 1
                            //（浅滩格 tops≈sea 时 yb=sea-S 会穿到负值）
                            int nbTop = nbOk
                                ? (biome[ni] == 0 ? _seaLevel - 1
                                    : tops[ni])
                                : Math.Max(tops[ci] - S, _seaLevel - 1);
                            yt = tops[ci];
                            if (yt > nbTop)
                            {
                                wall = true;
                                yb = nbTop;
                            }
                        }
                        float cx0 = centerX
                            + (cx - ShellRingOuter) * (float)S;
                        float cz0 = centerZ
                            + (cz - ShellRingOuter) * (float)S;
                        bool cont = wall && runStart >= 0
                            && yt == runTop && yb == runBot
                            && ci >= 0 && biome[ci] == runBiome
                            && b == runB + 1;
                        if (wall && !cont)
                        {
                            if (runStart >= 0)
                                EmitWall(runStart, runB);
                            runStart = b;
                            runB = b;
                            runTop = yt; runBot = yb;
                            runBiome = biome[ci];
                            runX0 = cx0; runZ0 = cz0;
                        }
                        else if (!wall && runStart >= 0)
                        {
                            EmitWall(runStart, runB);
                            runStart = -1;
                            runB = -1;
                        }
                        else if (wall)
                        {
                            runB = b;
                        }
                        // 局部函数：发射 [runStart, runB] 段墙
                        void EmitWall(int b0, int b1)
                        {
                            int ca = dz != 0 ? b0 : a;
                            int ca2 = dx != 0 ? b0 : a;
                            var col = Base(runBiome,
                                tint[ca * W + ca2]) * 0.9f;
                            float len = (b1 - b0 + 1) * (float)S;
                            Vector3 p0;
                            Vector3 t;
                            if (dx != 0)
                            {
                                p0 = new Vector3(
                                    runX0 + (dx > 0 ? S : 0),
                                    runBot, runZ0);
                                t = new Vector3(0, 0, len);
                            }
                            else
                            {
                                p0 = new Vector3(runX0, runBot,
                                    runZ0 + (dz > 0 ? S : 0));
                                t = new Vector3(len, 0, 0);
                            }
                            var up = new Vector3(0,
                                runTop - runBot, 0);
                            PushQuad(p0, p0 + t, p0 + up,
                                p0 + t + up, n, col);
                        }
                    }
                }
            }

            var arrays = new Godot.Collections.Array();
            arrays.Resize((int)Mesh.ArrayType.Max);
            arrays[(int)Mesh.ArrayType.Vertex] =
                Variant.CreateFrom(verts.ToArray());
            arrays[(int)Mesh.ArrayType.Normal] =
                Variant.CreateFrom(norms.ToArray());
            arrays[(int)Mesh.ArrayType.Color] =
                Variant.CreateFrom(cols.ToArray());
            arrays[(int)Mesh.ArrayType.Index] =
                Variant.CreateFrom(idxs.ToArray());
            mesh.AddSurfaceFromArrays(
                Mesh.PrimitiveType.Triangles, arrays);
        }
        return mesh;
    }
}
