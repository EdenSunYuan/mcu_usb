//============================================================================
// bs_threshold_scan — 2.5µs 门限逐拍扫描（SE0 走复位判据，K 走唤醒判据）
//
// 因: 把 SE0（已附着后）与 K（挂起中）各保持 116..130 拍，一段一段加
// 变: 每段都是隔离窗口：前后各 200 拍 J 静置，一段里线只变两次，
//     事件不可能跨窗口串到相邻拍上
// 果: 首次出现事件的拍数就是实测门限（两条判据共用一条计数器，门限应当一致）
// 判据: 门限以下（116..121）恰好 0 次；门限起（122..130）恰好 1 次翻转 + 1 个脉冲；
//       任何一段都不许出现多次翻转 / 多个脉冲（"判据单拍 → 只翻一次"的逐拍证据）
// 前文窗口: 先连接（rst_cond 需要 connected）
// 后文窗口: K 扫描前先重新挂起（rsm_cond 需要 suspended）
//============================================================================
task case_threshold_scan;
    integer n, first_se0, first_k;
    begin
        $display("  因: SE0 / K 各保持 116..130 拍，逐段隔离（前后各 200 拍 J 静置）");
        $display("  变: 到门限那拍 cnt_2p5u=1，判据出一次 → 翻转位翻一次");
        $display("  果: 首出拍数 = 实测门限；门限以下不出、门限以上只出一次");

        drive(1, 0, 300);                    // 先连接
        $display("  ---- SE0 扫描（rst_cond）----");
        first_se0 = -1;
        for (n = 116; n <= 130; n = n + 1) begin
            win_begin;
            drive(1, 0, 200);
            drive(0, 0, n);
            drive(1, 0, 200);
            win_end;
            $display("    SE0 %0d 拍: 判据 %0d, 翻转 %0d, 脉冲 %0d",
                     n, d_cond[2], d_mid[2], d_pulse[2]);
            if ((d_cond[2] > 1) || (d_mid[2] !== d_cond[2]) || (d_pulse[2] !== d_cond[2])) begin
                errors = errors + 1;
                $display("    FAIL SE0 %0d 拍: 判据/翻转/脉冲 出现多次或不等", n);
            end
            if ((d_cond[2] == 1) && (first_se0 < 0)) first_se0 = n;
        end
        $display("  实测 SE0 门限 = %0d 拍 = %0.3f µs（2.5µs 门限 + 2 拍流水：line_s 打拍、清零那拍）",
                 first_se0, first_se0 * 0.0208333);
        chk("se0_threshold_122", first_se0, 122);

        $display("  ---- K 扫描（rsm_cond）----");
        drive(1, 0, 144100);                 // 重新挂起
        chk("pre_suspended", u_dut.suspended, 1);
        first_k = -1;
        for (n = 116; n <= 130; n = n + 1) begin
            win_begin;
            drive(1, 0, 200);
            drive(0, 1, n);
            drive(1, 0, 200);
            win_end;
            $display("    K %0d 拍: 判据 %0d, 翻转 %0d, 脉冲 %0d",
                     n, d_cond[3], d_mid[3], d_pulse[3]);
            if ((d_cond[3] > 1) || (d_mid[3] !== d_cond[3]) || (d_pulse[3] !== d_cond[3])) begin
                errors = errors + 1;
                $display("    FAIL K %0d 拍: 判据/翻转/脉冲 出现多次或不等", n);
            end
            if (d_cond[3] == 1) begin
                if (first_k < 0) first_k = n;
                drive(1, 0, 144100);         // 挂起刚被解除，重新挂起（本窗口之外）
            end
        end
        $display("  实测 K 门限 = %0d 拍 = %0.3f µs", first_k, first_k * 0.0208333);
        chk("k_threshold_122", first_k, 122);
    end
endtask
